% downloadFIRMSHotspots.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux or Windows).
% TSRI ST 2571, Activity 1 prototype -- fire hotspot feed.
%
% Downloads NASA FIRMS near-real-time fire detections from the public
% no-key text feeds (same approach as haze_season_tracker_SEAsia.m, since
% the MAP_KEY area API returned 400 Bad Request), keeps detections inside
% ARCHIVE_BBOX, and appends only NEW detections to monthly archive files.
%
% ARCHIVE_BBOX covers mainland Southeast Asia rather than only Chiang Mai,
% so transboundary fires in Myanmar and Laos that send smoke into Chiang
% Mai are kept. The Chiang Mai count is printed separately each run.
%
% Feeds (rolling last 24 h, updated continuously by FIRMS):
%   VIIRS S-NPP, VIIRS NOAA-20, VIIRS NOAA-21 (375 m), MODIS Aqua/Terra (1 km)
% The SouthEast_Asia regional file is tried first (small download); if it
% fails, the Global file is used and filtered to ARCHIVE_BBOX.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true):
%   Once immediately, then every PERIOD_HOURS at MINUTE_PAST_HOUR.
%   Can run in the same MATLAB session as downloadPCDAllStationsMap.m
%   (PCD runs at :30, this at :15; a busy timer skips rather than queues).
%
% TO STOP:  stopPlatformTimers
%
% OUTPUTS (in outputDir):
%   FIRMS_Hotspots_YYYYMM.csv       deduplicated detections, by UTC month
%   FIRMS_Hotspots_latest24h.csv    detections in the box from this run (overwritten)
%   download_log.txt                errors / per-run summary
%
% Archive columns:
%   acq_datetime_utc, latitude, longitude, frp (MW), confidence
%   (VIIRS: l/n/h; MODIS: 0-100), satellite, daynight, feed

clear; clc;
%% ============================ CONFIG =======================================
% feed name | FIRMS folder | file prefix
cfg.feeds = { ...
    'VIIRS_SNPP',   'suomi-npp-viirs-c2', 'SUOMI_VIIRS_C2'; ...
    'VIIRS_NOAA20', 'noaa-20-viirs-c2',   'J1_VIIRS_C2'; ...
    'VIIRS_NOAA21', 'noaa-21-viirs-c2',   'J2_VIIRS_C2'; ...
    'MODIS',        'modis-c6.1',         'MODIS_C6_1'};
cfg.baseURL = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire';
cfg.regions = {'SouthEast_Asia', 'Global'};    % tried in this order

cfg.ARCHIVE_BBOX    = [92 5 110 25];           % W S E N, mainland Southeast Asia
cfg.CHIANGMAI_BBOX  = [97.9 17.1 99.7 20.3];   % for the per-run summary only

% --- Background scheduling ---
cfg.RUN_IN_BACKGROUND   = true;
cfg.PERIOD_HOURS        = 1;
cfg.MINUTE_PAST_HOUR    = 15;
cfg.REQUEST_TIMEOUT_SEC = 120;                 % Global fallback files are large

cfg.outputDir = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/FIRMS_Archive';
% ===========================================================================

if ~exist(cfg.outputDir, 'dir')
    mkdir(cfg.outputDir);
end
cfg.logFile = fullfile(cfg.outputDir, 'download_log.txt');

timerName = 'FIRMSHotspotsTimer';

existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A FIRMS timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

% --- Run once immediately ---
runFirmsCycleSafe(cfg);

% --- Then periodically, aligned to MINUTE_PAST_HOUR ---
if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    firmsTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600 * cfg.PERIOD_HOURS, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runFirmsCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('FIRMS timer error: %s\n', evt.Data.message));
    start(firmsTimer);

    fprintf('\nFIRMS hotspot downloader is now running in the background.\n');
    fprintf('Every %g h at :%02d (next run in %.0f seconds).\n', ...
        cfg.PERIOD_HOURS, cfg.MINUTE_PAST_HOUR, startDelaySec);
    fprintf('Files saved to: %s\n', cfg.outputDir);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runFirmsCycleSafe(cfg)
% A failed run is logged instead of killing the timer.
try
    runFirmsCycle(cfg);
catch ME
    fprintf('[%s] FIRMS cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | cycle failed: %s', datestr(now), ME.message));
end
end


function runFirmsCycle(cfg)
webOpts = weboptions('Timeout', cfg.REQUEST_TIMEOUT_SEC, 'CertificateFilename', '');
b = cfg.ARCHIVE_BBOX;

fprintf('[%s] Fetching FIRMS 24 h feeds...\n', datestr(now));
allNew = emptyHotspotTable();
nFeedsOK = 0;

for f = 1:size(cfg.feeds, 1)
    feedName = cfg.feeds{f, 1};
    gotFile  = false;
    for r = 1:numel(cfg.regions)
        url = sprintf('%s/%s/csv/%s_%s_24h.csv', cfg.baseURL, cfg.feeds{f, 2}, ...
            cfg.feeds{f, 3}, cfg.regions{r});
        tmp = [tempname '.csv'];
        try
            websave(tmp, url, webOpts);
            T = readFirmsCsv(tmp, feedName);
            delete(tmp);
            gotFile = true;
            usedRegion = cfg.regions{r};
            break;
        catch ME
            if exist(tmp, 'file')
                delete(tmp);
            end
            fprintf('  %-13s %s file failed (%s)\n', feedName, cfg.regions{r}, ME.message);
        end
    end
    if ~gotFile
        writeLog(cfg.logFile, sprintf('%s | ERROR | %s: no file could be downloaded', datestr(now), feedName));
        continue;
    end
    nFeedsOK = nFeedsOK + 1;

    inBox = T.longitude >= b(1) & T.longitude <= b(3) & ...
            T.latitude  >= b(2) & T.latitude  <= b(4);
    T = T(inBox, :);
    fprintf('  %-13s %5d detections in box (%s file)\n', feedName, height(T), usedRegion);
    allNew = [allNew; T]; %#ok<AGROW>
end

if nFeedsOK == 0
    error('No FIRMS feed could be downloaded.');
end

% --- Latest 24 h snapshot (overwritten each run) ---
allNew = sortrows(allNew, 'acq_datetime_utc');
allNew.acq_datetime_utc.Format = 'yyyy-MM-dd HH:mm';
writetable(allNew, fullfile(cfg.outputDir, 'FIRMS_Hotspots_latest24h.csv'));

% --- Append only new detections to the monthly archives ---
nAdded = 0;
if height(allNew) > 0
    ym = year(allNew.acq_datetime_utc) * 100 + month(allNew.acq_datetime_utc);
    monthsHere = unique(ym);
    for m = monthsHere(:)'
        sel = allNew(ym == m, :);
        fn  = fullfile(cfg.outputDir, sprintf('FIRMS_Hotspots_%d.csv', m));
        if exist(fn, 'file')
            old = readArchive(fn);
        else
            old = emptyHotspotTable();
        end
        combined = [old; sel];
        combined.acq_datetime_utc.Format = 'yyyy-MM-dd HH:mm';
        key = combined.feed + "_" + string(combined.acq_datetime_utc) + "_" + ...
              compose("%.4f_%.4f", combined.latitude, combined.longitude);
        [~, ia] = unique(key, 'first');            % keep already-archived rows
        nAdded = nAdded + numel(ia) - height(old);
        combined = sortrows(combined(ia, :), 'acq_datetime_utc');
        writetable(combined, fn);
    end
end

c = cfg.CHIANGMAI_BBOX;
inCM = allNew.longitude >= c(1) & allNew.longitude <= c(3) & ...
       allNew.latitude  >= c(2) & allNew.latitude  <= c(4);

msg = sprintf('%s | feeds OK=%d/%d | in box (24 h)=%d | Chiang Mai box=%d | newly archived=%d', ...
    datestr(now), nFeedsOK, size(cfg.feeds, 1), height(allNew), sum(inCM), nAdded);
writeLog(cfg.logFile, msg);
fprintf('[%s] Cycle done. %d detections in box (%d in Chiang Mai box), %d newly archived.\n', ...
    datestr(now), height(allNew), sum(inCM), nAdded);
end


function T = readFirmsCsv(file, feedName)
% Reads one FIRMS CSV (VIIRS or MODIS layout) into the standard table.
opts  = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',');
names = opts.VariableNames;
need  = {'latitude', 'longitude', 'acq_date', 'acq_time', 'frp', 'confidence', 'satellite', 'daynight'};
missing = setdiff(need, names);
if ~isempty(missing)
    error('FIRMS file is missing columns: %s', strjoin(missing, ', '));
end
opts = setvartype(opts, {'acq_date', 'satellite', 'confidence', 'daynight'}, 'char');
opts = setvartype(opts, {'latitude', 'longitude', 'acq_time', 'frp'}, 'double');
raw  = readtable(file, opts);

n = height(raw);
if n == 0
    T = emptyHotspotTable();
    return;
end
% acq_time is HHMM in UTC (e.g. 618 = 06:18)
t = datetime(raw.acq_date, 'InputFormat', 'yyyy-MM-dd') + ...
    hours(floor(raw.acq_time / 100)) + minutes(mod(raw.acq_time, 100));
T = table(t, raw.latitude, raw.longitude, raw.frp, string(raw.confidence), ...
    string(raw.satellite), string(raw.daynight), repmat(string(feedName), n, 1), ...
    'VariableNames', {'acq_datetime_utc', 'latitude', 'longitude', 'frp', ...
                      'confidence', 'satellite', 'daynight', 'feed'});
end


function T = readArchive(fn)
opts = detectImportOptions(fn, 'FileType', 'text', 'Delimiter', ',');
opts = setvartype(opts, {'acq_datetime_utc', 'confidence', 'satellite', 'daynight', 'feed'}, 'char');
opts = setvartype(opts, {'latitude', 'longitude', 'frp'}, 'double');
raw  = readtable(fn, opts);
if height(raw) == 0
    T = emptyHotspotTable();
    return;
end
T = table(datetime(raw.acq_datetime_utc, 'InputFormat', 'yyyy-MM-dd HH:mm'), ...
    raw.latitude, raw.longitude, raw.frp, string(raw.confidence), ...
    string(raw.satellite), string(raw.daynight), string(raw.feed), ...
    'VariableNames', {'acq_datetime_utc', 'latitude', 'longitude', 'frp', ...
                      'confidence', 'satellite', 'daynight', 'feed'});
end


function T = emptyHotspotTable()
T = table(NaT(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), strings(0, 1), ...
    strings(0, 1), strings(0, 1), strings(0, 1), ...
    'VariableNames', {'acq_datetime_utc', 'latitude', 'longitude', 'frp', ...
                      'confidence', 'satellite', 'daynight', 'feed'});
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
