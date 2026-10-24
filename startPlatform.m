% startPlatform.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- starts everything with one command.
%
%   0. checkPlatformMounts        Seagate drive present? HPC mount alive? (remounts if not)
%   1. downloadFIRMSHotspots      fire hotspots, hourly at :15
%   2. downloadPCDAllStationsMap  PCD stations, hourly at :30 (first run takes a few minutes)
%   3. downloadTMDAllStations     TMD weather, all 77 provinces, hourly at :02
%   3b. downloadNARITObservatories weather at NARIT observatories, every 10 min
%   3c. downloadLidarPBL          LiDAR PBL height (Google Drive via rclone), every 10 min
%   3d. downloadTMDRadarComposite TMD nationwide radar rain-rate composite, every 10 min
%   4. extractWRFForecast         WRF-Chem forecast, checked hourly at :05
%   5. exportDashboardData        dashboard.json + met_obs.json, hourly at :45
%   6. Web server                 python3 http.server on port 8080 (skipped if already running)
%   7. MountWatchdogTimer         re-runs checkPlatformMounts every 15 min
%
% Each script replaces its own timer if it is already running, so it is
% safe to run startPlatform again at any time (e.g. after a crash).
%
% NOTE: the called scripts start with "clear", which wipes this script's
% variables too. That is why every step below uses literal paths instead
% of variables defined at the top.
%
% TO STOP the timers:  stopPlatformTimers

clc;
fprintf('=== Starting Activity 1 platform: %s ===\n\n', datestr(now, 'yyyy-mm-dd HH:MM'));

% Folder holding the .m scripts (edit if yours are elsewhere). addpath
% survives "clear", so the scripts can be called by name below.
addpath('/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/scripts');

%% 0. Mounts
checkPlatformMounts;
if ~pmDriveOK
    fprintf(2, '\nStopped: the Seagate drive is not mounted, so there is nowhere to write data.\n');
    fprintf(2, 'Mount it (plug in / open it in the file manager), then run startPlatform again.\n');
    return;
end
if ~pmHpcOK
    fprintf(2, 'Continuing without the HPC: the forecast will not update until the mount works.\n\n');
end

%% 1. FIRMS hotspots
try
    downloadFIRMSHotspots;
catch startErr
    fprintf(2, 'downloadFIRMSHotspots failed to start: %s\n', startErr.message);
end

%% 2. PCD all stations
try
    downloadPCDAllStationsMap;
catch startErr
    fprintf(2, 'downloadPCDAllStationsMap failed to start: %s\n', startErr.message);
end

%% 3. TMD weather stations, all provinces (about 1-2 min)
try
    downloadTMDAllStations;
catch startErr
    fprintf(2, 'downloadTMDAllStations failed to start: %s\n', startErr.message);
end

%% 3b. NARIT observatory weather stations (writes the observatory list the forecast uses)
try
    downloadNARITObservatories;
catch startErr
    fprintf(2, 'downloadNARITObservatories failed to start: %s\n', startErr.message);
end

%% 3c. LiDAR PBL height (writes the LiDAR site list the forecast uses)
try
    downloadLidarPBL;
catch startErr
    fprintf(2, 'downloadLidarPBL failed to start: %s\n', startErr.message);
end

%% 3d. TMD radar composite (rain rate; map images for the Radar layer)
try
    downloadTMDRadarComposite;
catch startErr
    fprintf(2, 'downloadTMDRadarComposite failed to start: %s\n', startErr.message);
end

%% 4. WRF-Chem forecast (after PCD, TMD, NARIT and LiDAR, which write the station lists it uses)
try
    extractWRFForecast;
catch startErr
    fprintf(2, 'extractWRFForecast failed to start: %s\n', startErr.message);
end

%% 5. Dashboard export
try
    exportDashboardData;
catch startErr
    fprintf(2, 'exportDashboardData failed to start: %s\n', startErr.message);
end

%% 6. Web server
% "http[.]server" stops pgrep from matching its own shell command.
[notRunning, ~] = system('pgrep -f "http[.]server 8080"');
if notRunning
    system(['cd "/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/dashboard" && ' ...
            'nohup python3 -m http.server 8080 > /tmp/haze_dashboard_server.log 2>&1 &']);
    pause(1);
    [notRunning, ~] = system('pgrep -f "http[.]server 8080"');
    if notRunning
        fprintf(2, 'Web server did not start -- see /tmp/haze_dashboard_server.log\n');
    else
        fprintf('Web server started on port 8080.\n');
    end
else
    fprintf('Web server already running on port 8080.\n');
end

%% 7. Mount watchdog (checkPlatformMounts every 15 min; silent while all is well)
oldWatch = timerfind('Name', 'MountWatchdogTimer');
if ~isempty(oldWatch)
    stop(oldWatch);
    delete(oldWatch);
end
mountWatch = timer( ...
    'Name', 'MountWatchdogTimer', ...
    'ExecutionMode', 'fixedRate', ...
    'Period', 900, ...
    'StartDelay', 900, ...
    'BusyMode', 'drop', ...
    'TimerFcn', 'checkPlatformMounts;', ...
    'ErrorFcn', @(~,evt) fprintf('Mount watchdog error: %s\n', evt.Data.message));
start(mountWatch);

%% Summary
checkPlatformMounts;
fprintf('\n=== Platform status ===\n');
okText = {'NOT OK', 'OK'};
fprintf('  %-22s %s\n', 'Seagate drive', okText{pmDriveOK + 1});
fprintf('  %-22s %s\n', 'HPC mount', okText{pmHpcOK + 1});
expectedTimers = {'FIRMSHotspotsTimer', 'PCDAllStationsTimer', 'TMDAllStationsTimer', 'NARITObsTimer', 'LidarPBLTimer', 'TMDRadarTimer', 'WRFForecastTimer', ...
                  'DashboardExportTimer', 'MountWatchdogTimer'};
for i = 1:numel(expectedTimers)
    t = timerfind('Name', expectedTimers{i});
    if isempty(t)
        fprintf(2, '  %-22s NOT running\n', expectedTimers{i});
    else
        fprintf('  %-22s %s\n', expectedTimers{i}, t(1).Running);
    end
end
fprintf('  Dashboard: http://localhost:8080\n');
fprintf('Leave MATLAB open. To stop the timers: stopPlatformTimers\n');
