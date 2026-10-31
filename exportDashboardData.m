% exportDashboardData.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux or Windows).
% TSRI ST 2571, Activity 1 prototype -- data feed for the web dashboard.
%
% Does NOT download anything. It only reads what the existing scripts
% already write and packs it into one small JSON file for index.html:
%   downloadPCDAllStationsMap.m   -> PCD_Stations_latest.csv
%                                    PCD_MapValues_latest.csv
%                                    PCD_History_Archive.csv (last HISTORY_DAYS only)
%   downloadFIRMSHotspots.m       -> FIRMS_Hotspots_YYYYMM.csv (last HOTSPOT_DAYS)
%   haze_season_tracker_SEAsia.m  -> haze_tracker_log_SEAsia.csv
%   downloadTMDAllStations.m      -> TMD_AWS_latest.csv, TMD_AWS_YYYYMM.csv (last HISTORY_DAYS)
%   downloadNARITObservatories.m  -> NARIT_Observatories.csv, NARIT_Obs_latest.csv, NARIT_Obs_YYYYMM.csv
%   downloadLidarPBL.m            -> LIDAR_Sites.csv, LIDAR_PBL_YYYYMM.csv
% Any missing input is skipped; the dashboard shows what is available.
%
% Only the tail of PCD_History_Archive.csv is read (TAIL_MB), so the run
% stays fast as the archive grows.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true):
%   Once now, then hourly at MINUTE_PAST_HOUR (45 = after the PCD run at :30).
%   TO STOP: stopPlatformTimers
%
% OUTPUT:
%   <outDir>/dashboard.json   (written to a temp file first, then swapped in)
%   <outDir>/met_obs.json     TMD weather stations: latest values + hourly history
%   <outDir>/astro_obs.json   NARIT observatories: latest values + hourly means
%   <outDir>/lidar_obs.json   LiDAR sites: latest PBL height / aerosol layer top + hourly means (m AGL)

clear; clc;
%% ============================ CONFIG =======================================
cfg.rootDir     = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
cfg.pcdDir      = fullfile(cfg.rootDir, 'PCD_AllStations_Archive');
cfg.firmsDir    = fullfile(cfg.rootDir, 'FIRMS_Archive');
cfg.hazeLogFile = fullfile(cfg.rootDir, 'HazeTracker', 'haze_tracker_log_SEAsia.csv');  % edit to where the tracker writes its log
cfg.outDir      = fullfile(cfg.rootDir, 'dashboard', 'dashboard_data');
cfg.tmdDir      = fullfile(cfg.rootDir, 'TMD_AWS_Archive');
cfg.naritDir    = fullfile(cfg.rootDir, 'NARIT_Obs_Archive');
cfg.lidarDir    = fullfile(cfg.rootDir, 'LIDAR_PBL');
cfg.TMD_WIND_TO_MS = 1;   % TMD windSpeed -> m/s: 1 if TMD reports m/s, 1/3.6 if km/h (check one station on tmd.go.th)

cfg.pollutants   = {'PM25', 'PM10', 'O3', 'CO', 'NO2', 'SO2'};
cfg.HISTORY_DAYS = 7;     % station time series shown in the dashboard
cfg.HOTSPOT_DAYS = 3;     % fire hotspots shown on the map
cfg.TAIL_MB      = 20;    % bytes read from the end of the PCD archive (7 days ~ 4 MB)
% Add each station's latest reported value as the newest hour of its chart when the
% hourly archive has not caught up yet. Off: the latest values from the backup source
% (air4thai.com) can disagree with the hourly history (e.g. 189 vs ~20 ug/m3), and the
% charts and markers should show the hourly history only.
cfg.FILL_LATEST_FROM_MAP = false;

cfg.RUN_IN_BACKGROUND = true;
cfg.MINUTE_PAST_HOUR  = 45;
% ===========================================================================

if ~exist(cfg.outDir, 'dir')
    mkdir(cfg.outDir);
end

timerName = 'DashboardExportTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A dashboard export timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runExportSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    exportTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runExportSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('Dashboard export timer error: %s\n', evt.Data.message));
    start(exportTimer);

    fprintf('\nDashboard export is now running in the background.\n');
    fprintf('Hourly at :%02d (next run in %.0f seconds).\n', cfg.MINUTE_PAST_HOUR, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runExportSafe(cfg)
try
    runExport(cfg);
catch ME
    fprintf('[%s] Dashboard export failed: %s\n', datestr(now), ME.message);
end
end


function runExport(cfg)
P  = cfg.pollutants;
nP = numel(P);

nowLocal = datetime('now', 'TimeZone', 'Asia/Bangkok');
nowLocal.TimeZone = '';
nowUTC = datetime('now', 'TimeZone', 'UTC');
nowUTC.TimeZone = '';

%% ----- Stations + latest mapped values (PCD script output) -----
stFile = fullfile(cfg.pcdDir, 'PCD_Stations_latest.csv');
mvFile = fullfile(cfg.pcdDir, 'PCD_MapValues_latest.csv');
if ~exist(stFile, 'file') || ~exist(mvFile, 'file')
    error('PCD files not found in %s -- run downloadPCDAllStationsMap first.', cfg.pcdDir);
end
st = readTextTable(stFile, {'stationID', 'nameEN', 'areaEN', 'stationType', 'AQILast_time', 'nameTH', 'areaTH'});
hasTH = all(ismember({'nameTH', 'areaTH'}, st.Properties.VariableNames));   % Thai names, if the PCD script writes them
mv = readTextTable(mvFile, [{'stationID', 'nameEN'}, strcat(P, '_time')]);

nS = height(st);
mapVal  = nan(nS, nP);
mapTime = NaT(nS, nP);
[tf, loc] = ismember(st.stationID, mv.stationID);
for p = 1:nP
    if ~ismember(P{p}, mv.Properties.VariableNames)
        continue;
    end
    v  = mv.(P{p});
    tt = mv.([P{p} '_time']);
    for s = find(tf)'
        mapVal(s, p) = v(loc(s));
        if ~isempty(tt{loc(s)})
            mapTime(s, p) = datetime(tt{loc(s)}, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
        end
    end
end

%% ----- Hourly history: tail of the PCD archive -----
t0 = dateshift(nowLocal, 'start', 'hour') - days(cfg.HISTORY_DAYS);
hID = {};
hT  = NaT(0, 1);
hV  = nan(0, nP);

histFile = fullfile(cfg.pcdDir, 'PCD_History_Archive.csv');
if exist(histFile, 'file')
    fid = fopen(histFile, 'r', 'n', 'UTF-8');
    header    = strsplit(strtrim(fgetl(fid)), ',');
    dataStart = ftell(fid);
    fseek(fid, 0, 'eof');
    fileSize  = ftell(fid);
    startPos  = fileSize - cfg.TAIL_MB * 1e6;
    if startPos > dataStart
        fseek(fid, startPos, 'bof');
        fgetl(fid);                         % drop the partial first line
    else
        fseek(fid, dataStart, 'bof');
    end
    histPoll = header(6:end);               % stationID,nameEN,lat,lon,DATETIMEDATA,<pollutants>
    fmt = ['%q%q%f%f%q' repmat('%f', 1, numel(histPoll))];
    C = textscan(fid, fmt, 'Delimiter', ',', 'EndOfLine', '\n');
    fclose(fid);

    nRow = min(cellfun(@numel, C));         % guard against a half-written last line
    t = NaT(nRow, 1);
    okT = ~cellfun(@isempty, C{5}(1:nRow));
    t(okT) = datetime(C{5}(okT), 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    keep = find(~isnat(t) & t >= t0);

    hID = C{1}(keep);
    hT  = t(keep);
    hV  = nan(numel(keep), nP);
    for p = 1:nP
        j = find(strcmp(histPoll, P{p}), 1);
        if ~isempty(j)
            col = C{5 + j};
            hV(:, p) = col(keep);
        end
    end
end

% Common hourly axis from t0 to the newest value (archived or latest map value)
tEnd = max([hT; mapTime(~isnat(mapTime))]);
if isempty(tEnd) || isnat(tEnd)
    tEnd = nowLocal;
end
tEnd = dateshift(tEnd, 'start', 'hour');
nT   = round(hours(tEnd - t0)) + 1;

stations = cell(nS, 1);
series   = cell(nS, 1);
for s = 1:nS
    M = nan(nT, nP);
    idx = find(strcmp(hID, st.stationID{s}));
    if ~isempty(idx)
        k  = round(hours(hT(idx) - t0)) + 1;
        ok = k >= 1 & k <= nT;
        M(k(ok), :) = hV(idx(ok), :);
    end
    % Add the latest (not yet archived) hour from the map values (if enabled)
    for p = 1:nP
        if cfg.FILL_LATEST_FROM_MAP && ~isnat(mapTime(s, p))
            k = round(hours(mapTime(s, p) - t0)) + 1;
            if k >= 1 && k <= nT && isnan(M(k, p))
                M(k, p) = mapVal(s, p);
            end
        end
    end

    r = struct();
    r.id   = st.stationID{s};
    r.name = st.nameEN{s};
    r.area = st.areaEN{s};
    if hasTH
        r.name_th = st.nameTH{s};
        r.area_th = st.areaTH{s};
    else
        r.name_th = '';
        r.area_th = '';
    end
    r.type = st.stationType{s};
    r.lat  = st.lat(s);
    r.lon  = st.lon(s);
    q = struct();
    q.id = st.stationID{s};
    for p = 1:nP
        r.(P{p}) = round(mapVal(s, p), 2);
        r.([P{p} '_time']) = dtStr(mapTime(s, p));
        q.(P{p}) = round(M(:, p), 2);
    end
    stations{s} = r;
    series{s}   = q;
end

%% ----- Fire hotspots: last HOTSPOT_DAYS from the monthly FIRMS archives -----
hs.t = {}; hs.lat = []; hs.lon = []; hs.frp = []; hs.feed = {};
cutoff = nowUTC - days(cfg.HOTSPOT_DAYS);
monthsNeeded = unique([year(cutoff) * 100 + month(cutoff), year(nowUTC) * 100 + month(nowUTC)]);
for m = monthsNeeded
    fn = fullfile(cfg.firmsDir, sprintf('FIRMS_Hotspots_%d.csv', m));
    if ~exist(fn, 'file')
        continue;
    end
    H = readTextTable(fn, {'acq_datetime_utc', 'confidence', 'satellite', 'daynight', 'feed'});
    if height(H) == 0
        continue;
    end
    tt = datetime(H.acq_datetime_utc, 'InputFormat', 'yyyy-MM-dd HH:mm');
    k  = tt >= cutoff;
    hs.t    = [hs.t;    H.acq_datetime_utc(k)];
    hs.lat  = [hs.lat;  H.latitude(k)];
    hs.lon  = [hs.lon;  H.longitude(k)];
    hs.frp  = [hs.frp;  round(H.frp(k), 1)];
    hs.feed = [hs.feed; H.feed(k)];
end

%% ----- Haze season tracker log -----
haze = [];
if exist(cfg.hazeLogFile, 'file')
    textCols = {'run_date', 'oni_month', 'precip_note', 'air4thai_note', ...
        'campaign_note1', 'campaign_note2', 'plain_language1', 'plain_language2'};
    Hz = readTextTable(cfg.hazeLogFile, textCols);
    wanted = {'run_date', 'oni_anomaly_C', 'oni_month', 'fire_count', 'fire_window_days', ...
        'precip_anomaly_pct', 'precip_note', 'air4thai_mean_pm25', ...
        'campaign_note1', 'campaign_note2', 'plain_language1', 'plain_language2'};
    wanted = wanted(ismember(wanted, Hz.Properties.VariableNames));
    if height(Hz) > 0
        haze = table2struct(Hz(:, wanted));
    end
else
    fprintf('Haze tracker log not found (%s) -- season outlook left empty.\n', cfg.hazeLogFile);
end

%% ----- TMD weather stations -> met_obs.json -----
try
    exportTmd(cfg, t0);
catch ME
    fprintf('TMD export skipped: %s\n', ME.message);
end

%% ----- NARIT observatories -> astro_obs.json -----
try
    exportNarit(cfg, t0);
catch ME
    fprintf('NARIT observatory export skipped: %s\n', ME.message);
end

%% ----- LiDAR PBL -> lidar_obs.json -----
try
    exportLidar(cfg, t0);
catch ME
    fprintf('LiDAR export skipped: %s\n', ME.message);
end

%% ----- Assemble and write -----
D = struct();
D.generated_local  = datestr(nowLocal, 'yyyy-mm-dd HH:MM');
D.pollutants       = P;
D.history_t0_local = dtStr(t0);
D.history_n        = nT;
D.history_days     = cfg.HISTORY_DAYS;
D.hotspot_days     = cfg.HOTSPOT_DAYS;
D.stations         = [stations{:}];
D.series           = [series{:}];
D.hotspots         = hs;
D.haze             = haze;

outFile = fullfile(cfg.outDir, 'dashboard.json');
tmpFile = [outFile '.tmp'];
fid = fopen(tmpFile, 'w', 'n', 'UTF-8');
if fid == -1
    error('Cannot write %s', tmpFile);
end
fprintf(fid, '%s', jsonencode(D));
fclose(fid);
movefile(tmpFile, outFile, 'f');

fprintf('[%s] dashboard.json written: %d stations, %d h of history, %d hotspots, %d tracker rows.\n', ...
    datestr(now), nS, nT, numel(hs.lat), numel(haze));
end


function exportTmd(cfg, t0)
% Latest TMD readings + hourly history since t0 -> met_obs.json
latestFile = fullfile(cfg.tmdDir, 'TMD_AWS_latest.csv');
if ~exist(latestFile, 'file')
    return;
end
txt = {'stationId', 'nameEn', 'province', 'dateTimeLocal'};
L = readTextTable(latestFile, txt);
nS = height(L);
ids = L.stationId;

% Archive rows from t0 on (this month and, if needed, the previous one)
tNow = datetime('now');
months = unique([year(t0) * 100 + month(t0), year(tNow) * 100 + month(tNow)]);
A = table();
for m = months
    fn = fullfile(cfg.tmdDir, sprintf('TMD_AWS_%d.csv', m));
    if exist(fn, 'file')
        A = [A; readTextTable(fn, txt)]; %#ok<AGROW>
    end
end

vars    = {'TEMP', 'RH', 'WIND', 'WDIR', 'RAIN'};
cols    = {'temperature', 'humidity', 'windSpeed', 'windDirection', 'precip1Hr'};
factors = [1, 1, cfg.TMD_WIND_TO_MS, 1, 1];
dec     = [1, 0, 1, 0, 1];

tLatest = datetime(L.dateTimeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
tEnd = dateshift(max(tLatest), 'start', 'hour');
if isnat(tEnd), tEnd = dateshift(datetime('now'), 'start', 'hour'); end
nT = max(1, round(hours(tEnd - t0)) + 1);
H = nan(nS, nT, numel(vars));
if height(A) > 0
    tA = datetime(A.dateTimeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    [tA, ord] = sort(tA);                            % later readings overwrite earlier in the same hour
    A = A(ord, :);
    [tf, si] = ismember(A.stationId, ids);
    k  = round(hours(tA - t0)) + 1;
    ok = tf & k >= 1 & k <= nT;
    for v = 1:numel(vars)
        H(sub2ind(size(H), si(ok), k(ok), v * ones(sum(ok), 1))) = A.(cols{v})(ok) * factors(v);
    end
end

st = cell(nS, 1); se = cell(nS, 1);
for s = 1:nS
    r = struct('id', ['T' ids{s}], 'name', L.nameEn{s}, 'area', L.province{s}, ...
               'lat', L.lat(s), 'lon', L.lon(s));
    q = struct('id', ['T' ids{s}]);
    for v = 1:numel(vars)
        r.(vars{v}) = round(L.(cols{v})(s) * factors(v), dec(v));
        r.([vars{v} '_time']) = L.dateTimeLocal{s};
        q.(vars{v}) = round(H(s, :, v), dec(v));
    end
    st{s} = r; se{s} = q;
end

M = struct();
M.generated_local  = datestr(datetime('now'), 'yyyy-mm-dd HH:MM');
M.history_t0_local = datestr(t0, 'yyyy-mm-dd HH:MM:SS');
M.history_n        = nT;
M.stations         = [st{:}];
M.series           = [se{:}];

outFile = fullfile(cfg.outDir, 'met_obs.json');
fid = fopen([outFile '.tmp'], 'w', 'n', 'UTF-8');
fprintf(fid, '%s', jsonencode(M));
fclose(fid);
movefile([outFile '.tmp'], outFile, 'f');
fprintf('  met_obs.json written: %d TMD stations, %d h of history.\n', nS, nT);
end


function exportNarit(cfg, t0)
% Observatory list, newest record and hourly means since t0 -> astro_obs.json
listFile = fullfile(cfg.naritDir, 'NARIT_Observatories.csv');
if ~exist(listFile, 'file')
    return;
end
O = readTextTable(listFile, {'code', 'name', 'province'});
nS = height(O);

vars = {'ATEMP', 'ARH', 'AWIND', 'ADPS', 'APRES', 'ARAIN', 'ASOLAR'};
dec  = [1, 0, 1, 1, 1, 1, 0];

% DIMM seeing (separate archive; TNO only)
SE = table();
for m = unique([year(t0) * 100 + month(t0), year(datetime('now')) * 100 + month(datetime('now'))])
    fn = fullfile(cfg.naritDir, sprintf('NARIT_Seeing_%d.csv', m));
    if exist(fn, 'file')
        SE = [SE; readTextTable(fn, {'code', 'timeLocal'})]; %#ok<AGROW>
    end
end
colOf = @(T, v) obsColumn(T, v);

% Newest record per observatory
L = table();
latestFile = fullfile(cfg.naritDir, 'NARIT_Obs_latest.csv');
if exist(latestFile, 'file')
    L = readTextTable(latestFile, {'code', 'timeLocal'});
end

% Archive since t0
tNow = datetime('now');
A = table();
for m = unique([year(t0) * 100 + month(t0), year(tNow) * 100 + month(tNow)])
    fn = fullfile(cfg.naritDir, sprintf('NARIT_Obs_%d.csv', m));
    if exist(fn, 'file')
        A = [A; readTextTable(fn, {'code', 'timeLocal'})]; %#ok<AGROW>
    end
end

tEnd = dateshift(tNow, 'start', 'hour');
nT = round(hours(tEnd - t0)) + 1;
H = nan(nS, nT, numel(vars));
WD = nan(nS, nT);
if height(A) > 0
    tA = datetime(A.timeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    [tf, si] = ismember(A.code, O.code);
    k  = round(hours(tA - t0)) + 1;                  % hourly means centred on the hour
    ok = tf & k >= 1 & k <= nT;
    sub = [si(ok), k(ok)];
    for v = 1:numel(vars)
        x = colOf(A, vars{v});
        x = x(ok);
        good = isfinite(x);
        if any(good)
            sm = accumarray(sub(good, :), x(good), [nS nT]);
            cn = accumarray(sub(good, :), 1, [nS nT]);
            mv = sm ./ cn;
            mv(cn == 0) = NaN;
            H(:, :, v) = mv;
        end
    end
    d = A.wind_dir_deg(ok);
    good = isfinite(d);
    if any(good)                                      % circular mean of wind direction
        su = accumarray(sub(good, :), sind(d(good)), [nS nT]);
        cu = accumarray(sub(good, :), cosd(d(good)), [nS nT]);
        cn = accumarray(sub(good, :), 1, [nS nT]);
        WD = mod(atan2d(su, cu), 360);
        WD(cn == 0) = NaN;
    end
end

SH = nan(nS, nT);
seeLatest = nan(nS, 1); seeLatestT = repmat({''}, nS, 1);
if height(SE) > 0
    tS = datetime(SE.timeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    [tS, ord] = sort(tS);
    SE = SE(ord, :);
    [tf, si] = ismember(SE.code, O.code);
    k  = round(hours(tS - t0)) + 1;
    ok = tf & k >= 1 & k <= nT & isfinite(SE.seeing_arcsec);
    if any(ok)
        sm = accumarray([si(ok), k(ok)], SE.seeing_arcsec(ok), [nS nT]);
        cn = accumarray([si(ok), k(ok)], 1, [nS nT]);
        SH = sm ./ cn;
        SH(cn == 0) = NaN;
        for s = unique(si(ok))'
            j = find(ok & si == s, 1, 'last');
            seeLatest(s) = SE.seeing_arcsec(j);
            seeLatestT{s} = SE.timeLocal{j};
        end
    end
end

st = cell(nS, 1); se = cell(nS, 1);
for s = 1:nS
    id = ['A' O.code{s}];
    r = struct('id', id, 'name', O.name{s}, 'area', O.province{s}, 'lat', O.lat(s), 'lon', O.lon(s), ...
               'elev', O.elev_m(s));
    q = struct('id', id);
    j = [];
    if height(L) > 0
        j = find(strcmp(L.code, O.code{s}), 1);
    end
    for v = 1:numel(vars)
        if ~isempty(j)
            x = colOf(L(j, :), vars{v});
            r.(vars{v}) = round(x, dec(v));
            r.([vars{v} '_time']) = L.timeLocal{j};
        else
            r.(vars{v}) = NaN;
            r.([vars{v} '_time']) = '';
        end
        q.(vars{v}) = round(H(s, :, v), dec(v));
    end
    if ~isempty(j)
        r.AWDIR = round(L.wind_dir_deg(j));
    else
        r.AWDIR = NaN;
    end
    q.AWDIR = round(WD(s, :));
    r.ASEEING = round(seeLatest(s), 2);
    r.ASEEING_time = seeLatestT{s};
    q.ASEEING = round(SH(s, :), 2);
    st{s} = r; se{s} = q;
end

M = struct();
M.generated_local  = datestr(tNow, 'yyyy-mm-dd HH:MM');
M.history_t0_local = datestr(t0, 'yyyy-mm-dd HH:MM:SS');
M.history_n        = nT;
M.stations         = [st{:}];
M.series           = [se{:}];

outFile = fullfile(cfg.outDir, 'astro_obs.json');
fid = fopen([outFile '.tmp'], 'w', 'n', 'UTF-8');
fprintf(fid, '%s', jsonencode(M));
fclose(fid);
movefile([outFile '.tmp'], outFile, 'f');
fprintf('  astro_obs.json written: %d observatories, %d archive records.\n', nS, height(A));
end


function exportLidar(cfg, t0)
% LiDAR PBL height and aerosol layer top: newest 5-min value + hourly means since t0
listFile = fullfile(cfg.lidarDir, 'LIDAR_Sites.csv');
if ~exist(listFile, 'file')
    return;
end
O = readTextTable(listFile, {'code', 'name', 'province'});
nS = height(O);
tNow = datetime('now');
A = table();
for m = unique([year(t0) * 100 + month(t0), year(tNow) * 100 + month(tNow)])
    fn = fullfile(cfg.lidarDir, sprintf('LIDAR_PBL_%d.csv', m));
    if exist(fn, 'file')
        A = [A; readTextTable(fn, {'code', 'timeLocal'})]; %#ok<AGROW>
    end
end
tEnd = dateshift(tNow, 'start', 'hour');
nT = round(hours(tEnd - t0)) + 1;
cols = {'pbl_m', 'alt_m'}; vars = {'PBLH', 'ALT'};
H = nan(nS, nT, 2);
latest = nan(nS, 2); latestT = repmat({''}, nS, 1);
if height(A) > 0
    tA = datetime(A.timeLocal, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');
    [tA, ord] = sort(tA);
    A = A(ord, :);
    [tf, si] = ismember(A.code, O.code);
    k  = round(hours(tA - t0)) + 1;
    for v = 1:2
        x = A.(cols{v});
        ok = tf & k >= 1 & k <= nT & isfinite(x);
        if any(ok)
            sm = accumarray([si(ok), k(ok)], x(ok), [nS nT]);
            cn = accumarray([si(ok), k(ok)], 1, [nS nT]);
            h = sm ./ cn; h(cn == 0) = NaN;
            H(:, :, v) = h;
        end
    end
    for s = 1:nS
        j = find(tf & si == s & isfinite(A.pbl_m), 1, 'last');
        if ~isempty(j)
            latest(s, :) = [A.pbl_m(j), A.alt_m(j)];
            latestT{s} = A.timeLocal{j};
        end
    end
end
st = cell(nS, 1); se = cell(nS, 1);
for s = 1:nS
    id = ['L' O.code{s}];
    r = struct('id', id, 'name', O.name{s}, 'area', O.province{s}, 'lat', O.lat(s), 'lon', O.lon(s));
    q = struct('id', id);
    for v = 1:2
        r.(vars{v}) = round(latest(s, v));
        r.([vars{v} '_time']) = latestT{s};
        q.(vars{v}) = round(H(s, :, v));
    end
    st{s} = r; se{s} = q;
end
M = struct();
M.generated_local  = datestr(tNow, 'yyyy-mm-dd HH:MM');
M.history_t0_local = datestr(t0, 'yyyy-mm-dd HH:MM:SS');
M.history_n        = nT;
M.stations         = [st{:}];
M.series           = [se{:}];
outFile = fullfile(cfg.outDir, 'lidar_obs.json');
fid = fopen([outFile '.tmp'], 'w', 'n', 'UTF-8');
fprintf(fid, '%s', jsonencode(M));
fclose(fid);
movefile([outFile '.tmp'], outFile, 'f');
fprintf('  lidar_obs.json written: %d site(s), %d archive records.\n', nS, height(A));
end


function x = obsColumn(T, v)
% Dashboard variable from the observatory archive columns
switch v
    case 'ATEMP',  x = T.temp_C;
    case 'ARH',    x = T.rh_pct;
    case 'AWIND',  x = T.wind_ms;
    case 'ADPS',   x = max(T.temp_C - T.dewpoint_C, 0);
    case 'APRES',  x = T.pressure_hPa;
    case 'ARAIN',  x = T.rain_rate_mmh;
    case 'ASOLAR', x = T.solar_Wm2;
end
end


function T = readTextTable(file, textCols)
% readtable with the given columns as text and all others as numbers.
opts = detectImportOptions(file, 'FileType', 'text', 'Delimiter', ',', 'Encoding', 'UTF-8');
textCols = textCols(ismember(textCols, opts.VariableNames));
numCols  = setdiff(opts.VariableNames, textCols);
if ~isempty(textCols)
    opts = setvartype(opts, textCols, 'char');
end
if ~isempty(numCols)
    opts = setvartype(opts, numCols, 'double');
end
T = readtable(file, opts);
end


function s = dtStr(t)
if isnat(t)
    s = '';
else
    s = datestr(t, 'yyyy-mm-dd HH:MM:SS');
end
end
