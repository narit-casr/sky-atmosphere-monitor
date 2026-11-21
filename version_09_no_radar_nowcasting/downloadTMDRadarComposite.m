% downloadTMDRadarComposite.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- TMD nationwide radar rain-rate mosaic.
%
% Source: TMD's nationwide radar composite, linked from
%   https://weather.tmd.go.th/composite/index_composite.html
% as data/composite.nc (also composite.ascii): a GRIB2 product converted to
% NetCDF with wgrib2. Regular grid, 0.01 deg, 4-22.5 N, 95-108 E; variable
% var0_1_203_surface (TMD-local code in the "moisture" category). Its values
% (mostly 0, continuous to ~60, a few up to ~110) behave like a rain rate in
% mm/h rather than reflectivity in dBZ, so it is treated as rain rate; each new
% frame is compared with the TMD rain gauges and the comparison is printed and
% logged, as a check on that assumption.
%
% Each cycle (every PERIOD_MIN minutes):
%   1. downloads composite.nc; if its time is newer than the last frame saved:
%   2. archives the frame (RADAR/TMD/TMD_composite_<yyyymmddHHMM>.mat, UTC);
%   3. writes a map image for the dashboard (transparent PNG, rows laid out in
%      Web Mercator so it sits correctly on the map, colours by rain-rate class);
%   4. rewrites dashboard_data/radar.json, listing the frames of the last
%      KEEP_HOURS, and removes older map images from the dashboard folder.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true). TO STOP: stopPlatformTimers
%
% OUTPUTS
%   <archiveDir>/TMD_composite_<yyyymmddHHMM>.mat   rain rate (lat x lon, single), lat, lon, timeUTC
%   <dashDir>/radar/TMD_<yyyymmddHHMM>.png          map images (last KEEP_HOURS)
%   <dashDir>/radar.json                            frame list, bounds, colour classes
%   <archiveDir>/download_log.txt                   new frames + gauge comparison

clear; clc;
%% ============================ CONFIG =======================================
cfg.url        = 'https://weather.tmd.go.th/composite/data/composite.nc';
cfg.varName    = 'var0_1_203_surface';
cfg.rootDir    = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.archiveDir = fullfile(cfg.rootDir, 'RADAR', 'TMD');
cfg.dashDir    = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.tmdLatest  = fullfile(cfg.rootDir, 'TMD_AWS_Archive', 'TMD_AWS_latest.csv');   % gauge check

cfg.KEEP_HOURS = 3;            % frames shown on the dashboard
cfg.UTC_OFFSET_H = 7;

% Rain-rate classes (mm/h): lower edges; below the first edge is left transparent
cfg.BINS   = [0.1 0.5 1 2 5 10 20 30 50 75 100];
cfg.COLORS = [170 210 255; 110 170 255;  40 110 255;   0 180  80; 120 210   0; 255 230   0; ...
              255 160   0; 255  80   0; 220   0   0; 200   0 160; 140   0 200];

cfg.RUN_IN_BACKGROUND = true;
cfg.PERIOD_MIN = 10;
% ===========================================================================

if ~exist(cfg.archiveDir, 'dir'), mkdir(cfg.archiveDir); end
if ~exist(fullfile(cfg.dashDir, 'radar'), 'dir'), mkdir(fullfile(cfg.dashDir, 'radar')); end
cfg.logFile = fullfile(cfg.archiveDir, 'download_log.txt');

timerName = 'TMDRadarTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A TMD radar timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runRadarCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'minute');
    nextRun  = nextRun + minutes(cfg.PERIOD_MIN - mod(minute(nextRun), cfg.PERIOD_MIN)) + seconds(20);
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    radarTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 60 * cfg.PERIOD_MIN, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runRadarCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('TMD radar timer error: %s\n', evt.Data.message));
    start(radarTimer);

    fprintf('\nTMD radar composite downloader is now running in the background.\n');
    fprintf('Every %d min (next run in %.0f seconds).\n', cfg.PERIOD_MIN, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runRadarCycleSafe(cfg)
try
    runRadarCycle(cfg);
catch ME
    fprintf('[%s] TMD radar cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), ME.message));
end
end


function runRadarCycle(cfg)
% 1. Download
tmp = [tempname '.nc'];
websave(tmp, cfg.url, weboptions('Timeout', 60, 'CertificateFilename', ''));
cleanup = onCleanup(@() delete(tmp));

tSec = ncread(tmp, 'time');
timeUTC = datetime(tSec(1), 'ConvertFrom', 'posixtime');          % unzoned, UTC
tag = datestr(timeUTC, 'yyyymmddHHMM');
matFile = fullfile(cfg.archiveDir, sprintf('TMD_composite_%s.mat', tag));
if exist(matFile, 'file')
    fprintf('[%s] TMD radar: frame %s UTC already saved.\n', datestr(now), datestr(timeUTC, 'yyyy-mm-dd HH:MM'));
    updateFrameList(cfg);
    return;
end

lat = double(ncread(tmp, 'latitude'));
lon = double(ncread(tmp, 'longitude'));
v = ncread(tmp, cfg.varName);                                      % lon x lat (x time)
v = squeeze(v(:, :, 1));
v(v > 1e19) = NaN;
R = single(v');                                                    % lat x lon, rain rate (mm/h)

% 2. Archive (compressed MAT; mostly NaN/zero, so small)
save(matFile, 'R', 'lat', 'lon', 'timeUTC');

% 3. Map image: rows resampled to Web Mercator, colours by rain-rate class
dlat = lat(2) - lat(1);
merc = @(la) log(tand(45 + la / 2));
latS = lat(1) - dlat / 2;  latN = lat(end) + dlat / 2;
yS = merc(latS);  yN = merc(latN);
H = numel(lat);
rowY   = yN - ((1:H)' - 0.5) / H * (yN - yS);                     % row 1 = north
rowLat = 2 * atand(exp(rowY)) - 90;
ri = min(max(round((rowLat - lat(1)) / dlat) + 1, 1), numel(lat));
img = double(R(ri, :));

cls = discretize(img, [cfg.BINS Inf]);                             % NaN below the first edge
ok = isfinite(cls);
rgb = zeros([size(img) 3], 'uint8');
for c = 1:3
    ch = zeros(size(img), 'uint8');
    ch(ok) = uint8(cfg.COLORS(cls(ok), c));
    rgb(:, :, c) = ch;
end
alpha = double(ok);
pngName = sprintf('TMD_%s.png', tag);
imwrite(rgb, fullfile(cfg.dashDir, 'radar', pngName), 'Alpha', alpha);

% Gauge check: radar rain rate at TMD stations vs their last-hour rain
msgGauge = gaugeCheck(cfg, R, lat, lon, timeUTC);

% 4. Frame list for the dashboard
updateFrameList(cfg);

msg = sprintf('%s | frame %s UTC | rain cells (>=%.1f mm/h): %d | max %.1f mm/h | %s', datestr(now), ...
    datestr(timeUTC, 'yyyy-mm-dd HH:MM'), cfg.BINS(1), sum(R(:) >= cfg.BINS(1)), max(R(:)), msgGauge);
writeLog(cfg.logFile, msg);
fprintf('[%s] TMD radar: new frame %s UTC, %d rain cells, max %.1f mm/h. %s\n', datestr(now), ...
    datestr(timeUTC, 'yyyy-mm-dd HH:MM'), sum(R(:) >= cfg.BINS(1)), max(R(:)), msgGauge);
end


function updateFrameList(cfg)
% radar.json: frames of the last KEEP_HOURS (newest frame time as reference)
files = dir(fullfile(cfg.archiveDir, 'TMD_composite_*.mat'));
tags = regexp({files.name}, '^TMD_composite_(\d{12})\.mat$', 'tokens', 'once');
okf = ~cellfun(@isempty, tags);
tags = sort(cellfun(@(c) c{1}, tags(okf), 'UniformOutput', false));
if isempty(tags)
    return;
end
t = datetime(tags, 'InputFormat', 'yyyyMMddHHmm');
keep = t >= t(end) - hours(cfg.KEEP_HOURS);
tags = tags(keep); t = t(keep);

% Bounds and grid from the newest frame
S = load(fullfile(cfg.archiveDir, sprintf('TMD_composite_%s.mat', tags{end})), 'lat', 'lon');
dlat = S.lat(2) - S.lat(1); dlon = S.lon(2) - S.lon(1);

fr = cell(numel(tags), 1);
for i = 1:numel(tags)
    png = sprintf('TMD_%s.png', tags{i});
    if ~exist(fullfile(cfg.dashDir, 'radar', png), 'file')
        continue;                                   % archived before the dashboard images existed
    end
    fr{i} = struct('time_utc', datestr(t(i), 'yyyy-mm-dd HH:MM'), ...
                   'time_local', datestr(t(i) + hours(cfg.UTC_OFFSET_H), 'yyyy-mm-dd HH:MM'), ...
                   'image', ['dashboard_data/radar/' png]);
end
fr = fr(~cellfun(@isempty, fr));

J = struct();
J.source  = 'TMD nationwide radar composite (weather.tmd.go.th/composite)';
J.units   = 'mm/h';
J.generated_local = datestr(datetime('now'), 'yyyy-mm-dd HH:MM');
J.bounds  = [S.lat(1) - dlat / 2, S.lon(1) - dlon / 2; S.lat(end) + dlat / 2, S.lon(end) + dlon / 2];
J.bins    = cfg.BINS;
J.colors  = cellfun(@(c) sprintf('#%02X%02X%02X', c), num2cell(cfg.COLORS, 2), 'UniformOutput', false);
J.frames  = [fr{:}];
writeJson(fullfile(cfg.dashDir, 'radar.json'), J);

% Remove dashboard images that dropped out of the window (the MAT archive stays)
imgs = dir(fullfile(cfg.dashDir, 'radar', 'TMD_*.png'));
for k = 1:numel(imgs)
    tk = regexp(imgs(k).name, '^TMD_(\d{12})\.png$', 'tokens', 'once');
    if ~isempty(tk) && ~ismember(tk{1}, tags)
        delete(fullfile(imgs(k).folder, imgs(k).name));
    end
end
end


function msg = gaugeCheck(cfg, R, lat, lon, timeUTC)
% Radar rain rate at TMD stations vs the stations' rain in the last hour
msg = 'gauge check: no TMD file';
if ~exist(cfg.tmdLatest, 'file')
    return;
end
opts = detectImportOptions(cfg.tmdLatest, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
opts = setvartype(opts, intersect({'stationId', 'nameEn', 'province', 'dateTimeLocal'}, opts.VariableNames), 'char');
T = readtable(cfg.tmdLatest, opts);
tLoc = datetime(T.dateTimeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
near = abs(hours(tLoc - (timeUTC + hours(cfg.UTC_OFFSET_H)))) <= 1;
dlat = lat(2) - lat(1); dlon = lon(2) - lon(1);
ri = round((T.lat - lat(1)) / dlat) + 1;  ci = round((T.lon - lon(1)) / dlon) + 1;
in = near & ri >= 1 & ri <= numel(lat) & ci >= 1 & ci <= numel(lon) & isfinite(T.precip1Hr);
if ~any(in)
    msg = 'gauge check: no gauges within 1 h of the radar time';
    return;
end
rr = double(R(sub2ind(size(R), ri(in), ci(in))));
g  = T.precip1Hr(in);
okp = isfinite(rr);
wetR = rr(okp) >= 0.1;  wetG = g(okp) >= 0.1;
msg = sprintf('gauge check: %d gauges; wet by radar %d, by gauge %d, both %d', ...
    sum(okp), sum(wetR), sum(wetG), sum(wetR & wetG));
both = wetR & wetG;
if sum(both) >= 3
    msg = sprintf('%s; median radar/gauge %.2f', msg, median(rr(both) ./ g(both)));
end
end


function writeJson(outFile, data)
tmpFile = [outFile '.tmp'];
fid = fopen(tmpFile, 'w', 'n', 'UTF-8');
if fid == -1
    error('Cannot write %s', tmpFile);
end
fprintf(fid, '%s', jsonencode(data));
fclose(fid);
movefile(tmpFile, outFile, 'f');
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
