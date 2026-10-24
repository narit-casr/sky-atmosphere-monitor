% stopPlatformTimers.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible.
%
% Stops and deletes the background timers of the Activity 1 platform:
%   - PCDAllStationsTimer   (downloadPCDAllStationsMap.m, hourly at :30)
%   - FIRMSHotspotsTimer    (downloadFIRMSHotspots.m, hourly at :15)
%   - DashboardExportTimer  (exportDashboardData.m, hourly at :45)
%   - TMDAllStationsTimer   (downloadTMDAllStations.m, hourly at :02)
%   - NARITObsTimer         (downloadNARITObservatories.m, every 10 min)
%   - LidarPBLTimer         (downloadLidarPBL.m, every 10 min)
%   - TMDRadarTimer         (downloadTMDRadarComposite.m, every 10 min)
%   - WRFForecastTimer      (extractWRFForecast.m, hourly at :05)
%   - MountWatchdogTimer    (startPlatform.m, checkPlatformMounts every 15 min)

timerNames = {'PCDAllStationsTimer', 'FIRMSHotspotsTimer', 'DashboardExportTimer', 'WRFForecastTimer', 'MountWatchdogTimer', 'TMDAllStationsTimer', 'NARITObsTimer', 'LidarPBLTimer', 'TMDRadarTimer'};

anyStopped = false;
for i = 1:numel(timerNames)
    t = timerfind('Name', timerNames{i});
    if ~isempty(t)
        stop(t);
        delete(t);
        fprintf('%s stopped.\n', timerNames{i});
        anyStopped = true;
    end
end

if ~anyStopped
    fprintf('No platform timers are currently running.\n');
end

% The web server started by startPlatform keeps running after the timers
% stop (the page then shows the last exported data). Set stopServer = true
% to stop it as well.
stopServer = false;
if stopServer
    [notFound, ~] = system('pkill -f "http[.]server 8080"');
    if notFound
        fprintf('No web server was running on port 8080.\n');
    else
        fprintf('Web server on port 8080 stopped.\n');
    end
end
