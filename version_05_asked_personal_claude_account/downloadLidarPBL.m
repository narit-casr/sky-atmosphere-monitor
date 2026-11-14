% downloadLidarPBL.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- LiDAR PBL height (miniMPL, AstroPark).
%
% Source: the NRT PBL retrieval (temperature-constrained Haar WCT,
% Macatangay et al., AMT 18, 4347-4356, 2025), uploaded to Google Drive as
%   ChiangMai-PBLH-Level_2_Release_03_NRT.csv
% a rolling 24 h file at 5 min resolution (local time), with
%   DateTime, ALT (aerosol layer top, km AGL), PBL (km AGL),
%   Cloud_Base / Cloud_Core / Cloud_Top (km), surface weather, ...
%
% Each cycle:
%   1. (if RCLONE_REMOTE is set) copies the file from the Drive folder with
%      rclone, as user arun (rclone's Google login lives in arun's home,
%      even when MATLAB runs as root). Leave RCLONE_REMOTE empty if the NRT
%      pipeline writes the file straight into localDir instead.
%   2. Appends rows newer than the last saved one to a monthly archive,
%      since the source file only ever holds the last 24 h.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true): every PERIOD_MIN min.
% TO STOP: stopPlatformTimers
%
% OUTPUTS (in archiveDir)
%   LIDAR_Sites.csv           LiDAR sites (code, name, province, lat, lon) -- also
%                             read by the forecast extraction and the export
%   LIDAR_PBL_YYYYMM.csv      archive: code, timeLocal, pbl_m, alt_m, cloud_base_m, cloud_top_m
%   lastState_Lidar.mat, download_log.txt
%
% ONE-TIME SETUP for the Drive copy (terminal, as arun -- not with sudo):
%   rclone config      -> new remote named gdrive, type drive, log in with the
%                         Google account that can see the LiDAR folder
%   rclone lsf gdrive: --drive-root-folder-id 1whfiDoQp1SFN-rMy-asSnx7lpivNrZ9s
%                      -> should list ChiangMai-PBLH-Level_2_Release_03_NRT.csv

clear; clc;
%% ============================ CONFIG =======================================
cfg.rootDir    = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.localDir   = fullfile(cfg.rootDir, 'LIDAR_PBL', 'incoming');   % where the NRT file lands
cfg.archiveDir = fullfile(cfg.rootDir, 'LIDAR_PBL');

% Google Drive copy with rclone ('' = skip, the file is written to localDir directly)
cfg.RCLONE_REMOTE   = 'gdrive:';
cfg.DRIVE_FOLDER_ID = '1whfiDoQp1SFN-rMy-asSnx7lpivNrZ9s';
cfg.LOCAL_USER      = 'arun';

% code | name | province | lat | lon | NRT file name
cfg.SITES = {
    'astropark', 'Princess Sirindhorn AstroPark (miniMPL LiDAR)', 'Chiang Mai', ...
        18.85320874844, 98.958930881653, 'ChiangMai-PBLH-Level_2_Release_03_NRT.csv';
    };

cfg.RUN_IN_BACKGROUND = true;
cfg.PERIOD_MIN = 10;
% ===========================================================================

if ~exist(cfg.localDir, 'dir'),   mkdir(cfg.localDir);   end
if ~exist(cfg.archiveDir, 'dir'), mkdir(cfg.archiveDir); end
cfg.logFile = fullfile(cfg.archiveDir, 'download_log.txt');

fid = fopen(fullfile(cfg.archiveDir, 'LIDAR_Sites.csv'), 'w', 'n', 'UTF-8');
fprintf(fid, 'code,name,province,lat,lon\n');
for k = 1:size(cfg.SITES, 1)
    o = cfg.SITES(k, :);
    fprintf(fid, '%s,"%s","%s",%.6f,%.6f\n', o{1}, o{2}, o{3}, o{4}, o{5});
end
fclose(fid);

timerName = 'LidarPBLTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A LiDAR PBL timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runLidarCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'minute');
    nextRun  = nextRun + minutes(cfg.PERIOD_MIN - mod(minute(nextRun), cfg.PERIOD_MIN)) + seconds(45);
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    lidarTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 60 * cfg.PERIOD_MIN, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runLidarCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('LiDAR PBL timer error: %s\n', evt.Data.message));
    start(lidarTimer);

    fprintf('\nLiDAR PBL downloader is now running in the background.\n');
    fprintf('Every %d min (next run in %.0f seconds).\n', cfg.PERIOD_MIN, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runLidarCycleSafe(cfg)
try
    runLidarCycle(cfg);
catch ME
    fprintf('[%s] LiDAR PBL cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), ME.message));
end
end


function runLidarCycle(cfg)
% 1. Copy from Google Drive
if ~isempty(cfg.RCLONE_REMOTE)
    [~, who] = system('whoami');
    if strcmp(strtrim(who), cfg.LOCAL_USER)
        as = '';
    else
        as = ['sudo -u ' cfg.LOCAL_USER ' '];
    end
    incl = strjoin(cellfun(@(f) sprintf('--include "%s"', f), cfg.SITES(:, 6)', 'UniformOutput', false), ' ');
    cmd = sprintf('%srclone copy %s "%s" --drive-root-folder-id %s %s 2>&1', ...
        as, cfg.RCLONE_REMOTE, cfg.localDir, cfg.DRIVE_FOLDER_ID, incl);
    [st, out] = system(cmd);
    if st ~= 0
        writeLog(cfg.logFile, sprintf('%s | ERROR | rclone: %s', datestr(now), strtrim(out)));
        fprintf('[%s] rclone failed: %s\n', datestr(now), strtrim(out));   % still archive what is there
    end
end

% 2. Archive new rows
stateFile = fullfile(cfg.archiveDir, 'lastState_Lidar.mat');
lastCodes = {}; lastT = NaT(0, 1);
if exist(stateFile, 'file')
    S = load(stateFile);
    if isfield(S, 'lastCodes'), lastCodes = S.lastCodes; lastT = S.lastT; end
end

summary = {};
for k = 1:size(cfg.SITES, 1)
    code = cfg.SITES{k, 1};
    fn = fullfile(cfg.localDir, cfg.SITES{k, 6});
    if ~exist(fn, 'file')
        summary{end+1} = sprintf('%s: no file', code); %#ok<AGROW>
        continue;
    end
    opts = detectImportOptions(fn, 'FileType', 'text', 'Delimiter', ',');
    opts = setvartype(opts, 'DateTime', 'char');
    % Read the needed columns as numbers even if detectImportOptions guessed text
    % (e.g. a column that is all NaN in the rows it sampled)
    numCols = intersect({'PBL', 'ALT', 'Cloud_Base', 'Cloud_Top'}, opts.VariableNames);
    opts = setvartype(opts, numCols, 'double');
    T = readtable(fn, opts);
    t = datetime(T.DateTime, 'InputFormat', 'yyyy-MM-dd HH:mm');
    ok = ~isnat(t);
    T = T(ok, :); t = t(ok);
    [t, ord] = sort(t);
    T = T(ord, :);

    j = find(strcmp(lastCodes, code), 1);
    if ~isempty(j)
        isNew = t > lastT(j);
    else
        isNew = true(size(t));
    end
    if any(isNew)
        km2m = @(name) 1000 * colOrNaN(T, name);
        V = [km2m('PBL'), km2m('ALT'), km2m('Cloud_Base'), km2m('Cloud_Top')];
        appendRows(cfg, code, t(isNew), V(isNew, :));
        if isempty(j)
            lastCodes{end+1, 1} = code; %#ok<AGROW>
            lastT(end+1, 1) = max(t);
        else
            lastT(j) = max(t);
        end
    end
    summary{end+1} = sprintf('%s: +%d', code, sum(isNew)); %#ok<AGROW>
end
save(stateFile, 'lastCodes', 'lastT');
writeLog(cfg.logFile, sprintf('%s | %s', datestr(now), strjoin(summary, ' | ')));
fprintf('[%s] LiDAR PBL: %s\n', datestr(now), strjoin(summary, ', '));
end


function x = colOrNaN(T, name)
if ismember(name, T.Properties.VariableNames)
    x = T.(name);
    if iscell(x) || isstring(x)
        x = str2double(x);
    end
    x = double(x);
else
    x = nan(height(T), 1);
end
end


function appendRows(cfg, code, t, V)
ym = year(t) * 100 + month(t);
for m = unique(ym)'
    sel = find(ym == m);
    fn = fullfile(cfg.archiveDir, sprintf('LIDAR_PBL_%d.csv', m));
    newFile = ~exist(fn, 'file');
    fid = fopen(fn, 'a', 'n', 'UTF-8');
    if newFile
        fprintf(fid, 'code,timeLocal,pbl_m,alt_m,cloud_base_m,cloud_top_m\n');
    end
    for i = sel'
        fprintf(fid, '%s,%s,%s\n', code, datestr(t(i), 'yyyy-mm-dd HH:MM:SS'), ...
            strjoin(arrayfun(@numOrNaNStr, V(i, :), 'UniformOutput', false), ','));
    end
    fclose(fid);
end
end


function s = numOrNaNStr(v)
if isnan(v)
    s = 'NaN';
else
    s = num2str(round(v), '%d');
end
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
