%% haze_season_tracker_mappedFire.m
%
% Mainland SEA Haze Season Tracker -- automated monthly pull
% Standalone script (no local functions), MATLAB R2018b compatible.
%
% Pulls what can be pulled automatically:
%   1. ONI / Nino 3.4 anomaly        -- NOAA CPC ASCII (public, no key)
%   2. Active fire detections        -- NASA FIRMS global NRT feed (public, no key)
%   3. Regional precip anomaly       -- Open-Meteo archive API vs 10-yr climatology (public, no key)
%   4. Air4Thai regional PM2.5       -- PCD public JSON feed, northern stations (public, no key)
% Still manual (no external source exists):
%   5. AstroPark PM2.5               -- reads from astroparkPM25File if you point it at your
%                                        aws-air-quality-pipeline output, else type in by hand
%
% Appends one row per run to a running CSV log so you have a full season
% history to plot later. Re-run monthly (or whenever), takes under a
% minute (the precip climatology pull is ~11 small API calls).
%
% Ronald C. Macatangay / ARUN -- generated for campaign planning use.

clear; clc; close all;

%% ---- USER SETTINGS ---------------------------------------------------

% FIRMS MAP_KEY -- get a free one at https://firms.modaps.eosdis.nasa.gov/api/map_key/
% (kept for reference; the fire pull below uses FIRMS's no-key global feed)
firmsMapKey = '5b2c9a794e6cd74bc6060d29d3738ce9';

% Bounding box used for the FIRE COUNT / summary stat (mainland SEA
% burning region -- N. Thailand / Myanmar / Laos). [west, south, east, north]
firmsBBox = [92, -11, 141, 29];

% Wider bounding box used only for the hotspot MAP panel -- all of
% mainland + maritime Southeast Asia (Myanmar through Philippines/Indonesia).
firmsMapBBox = [92, -11, 141, 29];

% How many days back to sum fire detections over
firmsDayRange = 7;

% AstroPark site coordinates -- used for the precip anomaly pull.
siteLat = 18.8510;
siteLon = 98.9580;

% Precip anomaly window and climatology baseline
precipWindowDays = 30;      % rolling window to sum rainfall over
climatologyYears = 2015:2024;  % years averaged for the "normal" baseline

% Northern Thailand provinces to average for the Air4Thai regional note
% (matched against each station's areaEN field, case-insensitive)
air4ThaiProvinces = {'Chiang Mai', 'Chiang Rai', 'Mae Hong Son', ...
    'Lampang', 'Lamphun', 'Phayao', 'Nan', 'Phrae', 'Tak'};

% Log file -- one row appended per run. Fixed path (not pwd) so every run
% appends to the same log, which exportDashboardData.m reads for the
% dashboard's season outlook. The PNG is saved in the same folder.
logFile = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/HazeTracker/haze_tracker_log_SEAsia.csv';
if ~exist(fileparts(logFile), 'dir')
    mkdir(fileparts(logFile));
end

% Still manual: AstroPark's own PM2.5 only exists in your own pipeline
% output (aws-air-quality-pipeline), so there's no external source to
% automate it from. Point astroparkPM25File at that pipeline's output
% CSV/text file if it has one, or leave it empty and type the value in
% by hand each run.
astroparkPM25File = '/media/arun/Seagate Backup Plus Drive/AstroPark_WeatherStation/AstroPark_Weather_Archive/PCD_35t_History.csv';
astroparkPM25      = NaN; % used if astroparkPM25File is empty
% Interpretation notes. With autoInterpretation = true they are written
% from this run's numbers (section 6), so they can't go stale. Set it to
% false to use the four manual lines below instead.
% (Avoid commas in notes: the log writer turns them into semicolons.)
autoInterpretation = true;
campaignNote1      = 'Neutral — pre-season baseline; no signal to act on yet.';
campaignNote2      = 'Re-check when ONI crosses +2.0°C or precip anomaly turns negative.';
plainLanguage1     = 'Everything is calm for now — nothing to worry about yet.';
plainLanguage2     = 'Start paying closer attention once the numbers show real warming or a dry stretch.';

% Thresholds for the automatic interpretation
northThaiBBox  = [97.3, 15.6, 101.4, 20.5]; % [W S E N] upper northern Thailand, for the local fire count
fireWatchNorth = 1000;   % 7-day detections in northThaiBBox that raise the level to PREPARE
fireActNorth   = 5000;   % ... and to ACT
pmModerate     = 25;     % northern mean PM2.5 (ug/m3) that raises the level to PREPARE
pmStandard     = 37.5;   % Thai 24-h PM2.5 standard (ug/m3); above it the level is ACT

%% ---- 1. ONI / Nino 3.4 anomaly (NOAA CPC, public ASCII) --------------

oniURL = 'https://www.cpc.ncep.noaa.gov/data/indices/oni.ascii.txt';

% R2018b ships an outdated root-certificate bundle, which can reject
% currently-valid server certs on some networks. Skipping MATLAB's own
% cert check (below) avoids that; the connection is still HTTPS/TLS.
webOpts = weboptions('Timeout', 30, 'CertificateFilename', '');

oniValue = NaN;
oniSeason = '';
oniTrendDate = [];
oniTrendValue = [];
oniTrendLabel = {};

try
    raw = webread(oniURL, webOpts);
    lines = strsplit(raw, newline);
    lines = lines(~cellfun(@isempty, strtrim(lines)));

    % File format (header row, then): SEAS YR TOTAL ANOM  -- last column is the anomaly
    lastLine = strtrim(lines{end});
    parts = strsplit(lastLine);

    if numel(parts) >= 4
        seas = parts{1};   % e.g. 'JAS' (3-month running season)
        yr   = parts{2};
        oniValue = str2double(parts{end});
        oniSeason = sprintf('%s %s', seas, yr);
        fprintf('ONI pulled OK: %+.2f degC (%s)\n', oniValue, oniSeason);
    else
        warning('ONI file format unexpected -- check URL/parsing manually.');
    end

    % Rolling 1-year window: pull the trailing 12 seasonal values from
    % the same file (it's the full history, one row per running-3-month
    % season) rather than waiting for 12 months of this script's own log.
    seasonMonth = containers.Map( ...
        {'DJF','JFM','FMA','MAM','AMJ','MJJ','JJA','JAS','ASO','SON','OND','NDJ'}, ...
        {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12});

    nTrail = min(12, numel(lines) - 1);
    oniTrendDate = nan(nTrail, 1);
    oniTrendValue = nan(nTrail, 1);
    oniTrendLabel = cell(nTrail, 1);

    for k = 1:nTrail
        lineParts = strsplit(strtrim(lines{end - nTrail + k}));
        if numel(lineParts) < 4 || ~isKey(seasonMonth, lineParts{1})
            continue;
        end
        oniTrendValue(k) = str2double(lineParts{end});
        oniTrendDate(k) = datenum(str2double(lineParts{2}), seasonMonth(lineParts{1}), 15);
        oniTrendLabel{k} = sprintf('%s %s', lineParts{1}, lineParts{2});
    end
catch ME
    warning('Could not pull ONI automatically: %s', ME.message);
    fprintf('  -> check by hand at https://www.cpc.ncep.noaa.gov/data/indices/oni.ascii.txt\n');
end

%% ---- 2. Active fire detections (NASA FIRMS global text feed, no key) --
%
% The parameterized area API (api/area/csv/[KEY]/[SOURCE]/[BBOX]/[DAYS])
% kept returning 400 Bad Request for this account/region combination even
% after switching sensors -- cause unconfirmed. Sidestepping it: FIRMS
% also publishes global NRT fire-detection text files with no MAP_KEY and
% no query parameters, updated continuously. We pull the global file for
% the chosen day window and filter to the bounding box ourselves.

fireCount = NaN;
fireLatInBox = [];
fireLonInBox = [];
fireLatMap = [];
fireLonMap = [];

if firmsDayRange <= 1
    fireURL = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Global_24h.csv';
elseif firmsDayRange <= 2
    fireURL = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Global_48h.csv';
else
    fireURL = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Global_7d.csv';
end

try
    fireRaw = webread(fireURL, webOpts);

    if istable(fireRaw)
        % webread auto-parsed the CSV into a table (MATLAB does this
        % based on the .csv extension) -- filter directly, no char split.
        varNames = fireRaw.Properties.VariableNames;
        latCol = varNames(strcmpi(varNames, 'latitude'));
        lonCol = varNames(strcmpi(varNames, 'longitude'));

        if isempty(latCol) || isempty(lonCol)
            warning('Could not find latitude/longitude columns in FIRMS table.');
        else
            lat = fireRaw.(latCol{1});
            lon = fireRaw.(lonCol{1});
            inBox = lon >= firmsBBox(1) & lon <= firmsBBox(3) & ...
                    lat >= firmsBBox(2) & lat <= firmsBBox(4);
            fireCount = sum(inBox);
            fireLatInBox = lat(inBox);
            fireLonInBox = lon(inBox);

            inMapBox = lon >= firmsMapBBox(1) & lon <= firmsMapBBox(3) & ...
                       lat >= firmsMapBBox(2) & lat <= firmsMapBBox(4);
            fireLatMap = lat(inMapBox);
            fireLonMap = lon(inMapBox);

            fprintf('FIRMS pulled OK: %d detections in bbox over last %d day(s) (of %d global)\n', ...
                fireCount, firmsDayRange, height(fireRaw));
        end
    else
        % Fell back to raw text -- parse by hand
        fireLines = strsplit(char(fireRaw), newline);
        fireLines = fireLines(~cellfun(@isempty, strtrim(fireLines)));

        if numel(fireLines) < 2
            warning('FIRMS global file returned no rows -- check URL by hand.');
        else
            headerParts = strsplit(fireLines{1}, ',');
            latCol = find(strcmpi(strtrim(headerParts), 'latitude'), 1);
            lonCol = find(strcmpi(strtrim(headerParts), 'longitude'), 1);

            if isempty(latCol) || isempty(lonCol)
                warning('Could not find latitude/longitude columns in FIRMS file header.');
            else
                fireCount = 0;
                fireLatInBox = [];
                fireLonInBox = [];
                fireLatMap = [];
                fireLonMap = [];
                for k = 2:numel(fireLines)
                    rowParts = strsplit(fireLines{k}, ',');
                    if numel(rowParts) < max(latCol, lonCol)
                        continue;
                    end
                    latVal = str2double(rowParts{latCol});
                    lonVal = str2double(rowParts{lonCol});
                    if lonVal >= firmsBBox(1) && lonVal <= firmsBBox(3) && ...
                       latVal >= firmsBBox(2) && latVal <= firmsBBox(4)
                        fireCount = fireCount + 1;
                        fireLatInBox(end+1) = latVal; %#ok<AGROW>
                        fireLonInBox(end+1) = lonVal; %#ok<AGROW>
                    end
                    if lonVal >= firmsMapBBox(1) && lonVal <= firmsMapBBox(3) && ...
                       latVal >= firmsMapBBox(2) && latVal <= firmsMapBBox(4)
                        fireLatMap(end+1) = latVal; %#ok<AGROW>
                        fireLonMap(end+1) = lonVal; %#ok<AGROW>
                    end
                end
                fprintf('FIRMS pulled OK: %d detections in bbox over last %d day(s) (of %d global)\n', ...
                    fireCount, firmsDayRange, numel(fireLines) - 1);
            end
        end
    end
catch ME
    warning('Could not pull FIRMS fire data: %s', ME.message);
    fprintf('  -> check by hand at %s\n', fireURL);
end

%% ---- 3. Regional precip anomaly (Open-Meteo archive, no key) ---------
%
% Sums rainfall at the AstroPark site over the last precipWindowDays and
% compares it to the average for the same calendar window across
% climatologyYears. Open-Meteo's reanalysis archive typically lags by
% about a week, so the window ends 7 days ago rather than today.

precipAnomalyPct = NaN;
precipNote = '';

try
    endDate = datetime(now, 'ConvertFrom', 'datenum') - days(7);
    startDate = endDate - days(precipWindowDays - 1);

    currentURL = sprintf(['https://archive-api.open-meteo.com/v1/archive?', ...
        'latitude=%.4f&longitude=%.4f&start_date=%s&end_date=%s', ...
        '&daily=precipitation_sum&timezone=Asia%%2FBangkok'], ...
        siteLat, siteLon, datestr(startDate, 'yyyy-mm-dd'), datestr(endDate, 'yyyy-mm-dd'));

    currentData = webread(currentURL, webOpts);
    currentSum = sum(currentData.daily.precipitation_sum, 'omitnan');

    climSums = nan(1, numel(climatologyYears));
    for yIdx = 1:numel(climatologyYears)
        yr = climatologyYears(yIdx);
        climStart = datetime(yr, month(startDate), day(startDate));
        climEnd = climStart + days(precipWindowDays - 1);
        climURL = sprintf(['https://archive-api.open-meteo.com/v1/archive?', ...
            'latitude=%.4f&longitude=%.4f&start_date=%s&end_date=%s', ...
            '&daily=precipitation_sum&timezone=Asia%%2FBangkok'], ...
            siteLat, siteLon, datestr(climStart, 'yyyy-mm-dd'), datestr(climEnd, 'yyyy-mm-dd'));
        try
            climData = webread(climURL, webOpts);
            climSums(yIdx) = sum(climData.daily.precipitation_sum, 'omitnan');
        catch
            % one bad year shouldn't kill the whole climatology -- skip it
        end
    end

    climMean = mean(climSums, 'omitnan');
    nClimYears = sum(~isnan(climSums));

    if nClimYears >= 3 && climMean > 0
        precipAnomalyPct = (currentSum - climMean) / climMean * 100;
        precipNote = sprintf('Open-Meteo: %.0fmm over %dd (%s to %s) vs %.0fmm clim mean (%d yrs, %d-%d)', ...
            currentSum, precipWindowDays, datestr(startDate, 'dd mmm'), datestr(endDate, 'dd mmm'), ...
            climMean, nClimYears, climatologyYears(1), climatologyYears(end));
        fprintf('Precip anomaly computed OK: %+.0f%% (%s)\n', precipAnomalyPct, precipNote);
    else
        warning('Too few climatology years came back (%d) to trust an anomaly.', nClimYears);
    end
catch ME
    warning('Could not compute precip anomaly: %s', ME.message);
    fprintf('  -> check by hand against the WMO/NOAA seasonal outlook.\n');
end

%% ---- 4. Air4Thai regional PM2.5 (PCD public JSON, no key) -------------
%
% Averages PM2.5 across northern Thailand stations (air4ThaiProvinces)
% from PCD's public real-time feed. This is a regional cross-check, not
% a substitute for AstroPark's own instrument reading.

air4ThaiNote = '';
air4ThaiMeanPM25 = NaN;

try
    air4ThaiURL = 'https://air4thai.pcd.go.th/services/getNewAQI_JSON.php';
    try
        a4tRaw = webread(air4ThaiURL, webOpts);
    catch
        % Some networks resolve/allow https but not plain http (or vice
        % versa) for .go.th domains -- try the other scheme once before
        % giving up.
        air4ThaiURL = 'http://air4thai.pcd.go.th/services/getNewAQI_JSON.php';
        a4tRaw = webread(air4ThaiURL, webOpts);
    end

    if ischar(a4tRaw) || isstring(a4tRaw)
        a4tData = jsondecode(char(a4tRaw));
    else
        a4tData = a4tRaw;  % webread may auto-decode JSON already
    end

    stations = a4tData.stations;
    pmVals = [];
    for sIdx = 1:numel(stations)
        st = stations(sIdx);
        areaTxt = '';
        if isfield(st, 'areaEN')
            areaTxt = lower(st.areaEN);
        end
        isNorthern = any(cellfun(@(p) contains(areaTxt, lower(p)), air4ThaiProvinces));
        if ~isNorthern || ~isfield(st, 'AQILast') || ~isfield(st.AQILast, 'PM25')
            continue;
        end
        pmField = st.AQILast.PM25;
        if isfield(pmField, 'value')
            v = str2double(pmField.value);
            if ~isnan(v) && v >= 0
                pmVals(end+1) = v; %#ok<AGROW>
            end
        end
    end

    if ~isempty(pmVals)
        air4ThaiMeanPM25 = mean(pmVals);
        air4ThaiNote = sprintf('Air4Thai: %.0f ug/m3 mean across %d northern stations', ...
            air4ThaiMeanPM25, numel(pmVals));
        fprintf('Air4Thai pulled OK: %s\n', air4ThaiNote);
    else
        warning('No valid PM2.5 readings found among northern Air4Thai stations.');
    end
catch ME
    warning('Could not pull Air4Thai data: %s', ME.message);
    fprintf('  -> check by hand at http://air4thai.pcd.go.th/\n');
end

%% ---- 5. AstroPark PM2.5 -- from your own pipeline file, or manual -----

if ~isempty(astroparkPM25File) && isfile(astroparkPM25File)
    try
        localTbl = readtable(astroparkPM25File);
        colNames = localTbl.Properties.VariableNames;
        normNames = regexprep(lower(colNames), '[^a-z0-9]', '');  % 'PM2.5' -> 'pm25'
        pmMatch = find(contains(normNames, 'pm25'), 1);
        if ~isempty(pmMatch)
            pmCol = colNames{pmMatch};
            colData = localTbl.(pmCol);
            colData = colData(~isnan(colData));
            if ~isempty(colData)
                astroparkPM25 = colData(end);  % most recent valid row
                fprintf('AstroPark PM2.5 read from file OK: %.1f ug/m3 (column "%s")\n', astroparkPM25, pmCol);
            else
                warning('PM2.5 column "%s" found but has no non-NaN values -- falling back to manual.', pmCol);
            end
        else
            warning('No PM2.5-like column found in %s -- falling back to manual value.', astroparkPM25File);
            fprintf('  Columns found: %s\n', strjoin(colNames, ', '));
        end
    catch ME
        warning('Could not read %s: %s -- falling back to manual value.', astroparkPM25File, ME.message);
    end
end

%% ---- 6. Interpret this run (automatic notes) ---------------------------
%
% Levels: CALM -> WATCH -> PREPARE -> ACT
%   Climate signal score: ONI >= +1.0 adds 1, >= +2.0 adds 2;
%                         rain <= -10 % adds 1, <= -25 % adds 2.
%   Score 0 = CALM, 1-2 = WATCH, 3+ = PREPARE.
%   What is happening now overrides upward: northern PM2.5 above
%   pmModerate or upper-north fires above fireWatchNorth -> at least
%   PREPARE; PM2.5 above pmStandard or fires above fireActNorth -> ACT.

if autoInterpretation
    runMonth = month(datetime('now', 'TimeZone', 'Asia/Bangkok'));

    % Upper northern Thailand fire count from the detections already pulled
    fireCountNorth = NaN;
    if ~isnan(fireCount)
        fireCountNorth = sum(fireLonInBox >= northThaiBBox(1) & fireLonInBox <= northThaiBBox(3) & ...
                             fireLatInBox >= northThaiBBox(2) & fireLatInBox <= northThaiBBox(4));
    end

    % El Nino strength
    if isnan(oniValue)
        ensoTxt = 'ENSO state unknown (ONI not available)';
        ensoScore = 0;
    else
        if oniValue >= 2.0
            ensoName = 'very strong El Niño'; ensoScore = 2;
        elseif oniValue >= 1.5
            ensoName = 'strong El Niño';      ensoScore = 1;
        elseif oniValue >= 1.0
            ensoName = 'moderate El Niño';    ensoScore = 1;
        elseif oniValue >= 0.5
            ensoName = 'weak El Niño';        ensoScore = 0;
        elseif oniValue > -0.5
            ensoName = 'ENSO-neutral';        ensoScore = 0;
        else
            ensoName = 'La Niña';             ensoScore = 0;
        end
        ensoTxt = sprintf('%s (ONI %+.2f°C %s)', ensoName, oniValue, oniSeason);
    end

    % Rainfall
    if isnan(precipAnomalyPct)
        rainTxt = 'rainfall anomaly not available';
        rainScore = 0;
    else
        if precipAnomalyPct <= -25
            rainName = 'much drier than normal rain'; rainScore = 2;
        elseif precipAnomalyPct <= -10
            rainName = 'drier than normal rain';      rainScore = 1;
        elseif precipAnomalyPct >= 10
            rainName = 'wetter than normal rain';     rainScore = 0;
        else
            rainName = 'near-normal rain';            rainScore = 0;
        end
        rainTxt = sprintf('%s (%+.0f%% over %d days)', rainName, precipAnomalyPct, precipWindowDays);
    end

    % Level from the climate signal, then raised by current conditions
    score = ensoScore + rainScore;
    if score >= 3
        level = 3;
    elseif score >= 1
        level = 2;
    else
        level = 1;
    end
    if air4ThaiMeanPM25 > pmModerate || fireCountNorth >= fireWatchNorth
        level = max(level, 3);
    end
    if air4ThaiMeanPM25 > pmStandard || fireCountNorth >= fireActNorth
        level = 4;
    end
    levelNames = {'CALM', 'WATCH', 'PREPARE', 'ACT'};

    if runMonth >= 1 && runMonth <= 4
        seasonTxt = 'during the burning season';
    elseif runMonth >= 10
        seasonTxt = 'ahead of the January to April burning season';
    else
        seasonTxt = 'during the wet season';
    end

    campaignNote1 = sprintf('%s — %s and %s %s.', levelNames{level}, ensoTxt, rainTxt, seasonTxt);

    nowParts = {};
    if ~isnan(air4ThaiMeanPM25)
        nowParts{end+1} = sprintf('northern stations average %.0f ug/m3 PM2.5', air4ThaiMeanPM25);
    end
    if ~isnan(fireCountNorth)
        nowParts{end+1} = sprintf('%d fire detections in upper northern Thailand over %d days', ...
            fireCountNorth, firmsDayRange);
    end
    if isempty(nowParts)
        nowTxt = '';
    else
        nowTxt = ['Now: ' strjoin(nowParts, ' and ') '. '];
    end
    actions = {'Re-check monthly.', ...
               'Re-check every two weeks.', ...
               'Check instruments and forecast runs before January; re-check every two weeks.', ...
               'Issue daily PM2.5 forecasts and keep the LiDAR running continuously.'};
    campaignNote2 = [nowTxt actions{level}];

    switch level
        case 1
            plainLanguage1 = 'Everything is calm for now — nothing to worry about yet.';
            plainLanguage2 = 'Start paying closer attention if the Pacific keeps warming or the rains fall short.';
        case 2
            plainLanguage1 = 'The signs are starting to point to a drier and smokier season ahead.';
            plainLanguage2 = 'Nothing to do yet — keep an eye on the next update.';
        case 3
            plainLanguage1 = 'The warning signs are in place: the coming smoke season is likely to start earlier and be worse than usual.';
            if isnan(air4ThaiMeanPM25) || air4ThaiMeanPM25 <= pmModerate
                plainLanguage2 = 'The air is still clean for now — use the coming weeks to get ready.';
            else
                plainLanguage2 = 'Smoke is already building — limit time outdoors on high-PM days.';
            end
        otherwise
            plainLanguage1 = 'Smoke season is under way and the air in the north is unhealthy or close to it.';
            plainLanguage2 = 'Follow the daily PM2.5 forecast and limit time outdoors on bad days.';
    end

    % The log writer turns commas into semicolons, so keep notes comma-free
    campaignNote1  = strrep(campaignNote1, ',', '');
    campaignNote2  = strrep(campaignNote2, ',', '');
    plainLanguage1 = strrep(plainLanguage1, ',', '');
    plainLanguage2 = strrep(plainLanguage2, ',', '');
end

%% ---- 7. Assemble this run's row ---------------------------------------

runDate = datestr(now, 'yyyy-mm-dd');

fprintf('\n========== HAZE SEASON TRACKER -- %s ==========\n', runDate);
fprintf('ONI / Nino 3.4 anomaly   : %+.2f degC  (%s)\n', oniValue, oniSeason);
fprintf('Fire detections (%d d)   : %d\n', firmsDayRange, numel(fireLatMap));
fprintf('Precip anomaly           : %+.0f %%   %s\n', precipAnomalyPct, precipNote);
fprintf('Note                     : %s\n', campaignNote1);
fprintf('                           %s\n', campaignNote2);
fprintf('Plain language           : %s\n', plainLanguage1);
fprintf('                           %s\n', plainLanguage2);
fprintf('====================================================\n\n');

% 2015-16 super El Nino benchmarks, for quick eyeballing against this run
fprintf('Analog check -- 2015-16 super El Nino peaked around ONI +2.6 degC (Nov-Dec).\n');
fprintf('1997-98 peaked around ONI +2.4 degC. Current run: %+.2f degC.\n\n', oniValue);

%% ---- 8. Append to running CSV log --------------------------------------

newRow = {runDate, oniValue, oniSeason, fireCount, firmsDayRange, ...
          precipAnomalyPct, precipNote, astroparkPM25, air4ThaiMeanPM25, air4ThaiNote, ...
          campaignNote1, campaignNote2, plainLanguage1, plainLanguage2};

headerRow = {'run_date', 'oni_anomaly_C', 'oni_month', 'fire_count', 'fire_window_days', ...
             'precip_anomaly_pct', 'precip_note', 'astropark_pm25', 'air4thai_mean_pm25', ...
             'air4thai_note', 'campaign_note1', 'campaign_note2', 'plain_language1', 'plain_language2'};

if isfile(logFile)
    % If an earlier run of this script wrote a different set of columns
    % (the tracker's fields have grown a few times), readtable will choke
    % on the mixed-width CSV. Detect that and archive the old log rather
    % than silently corrupt or lose it.
    fidCheck = fopen(logFile, 'r');
    existingHeader = strtrim(fgetl(fidCheck));
    fclose(fidCheck);

    if ~strcmp(existingHeader, strjoin(headerRow, ','))
        archiveFile = strrep(logFile, '.csv', sprintf('_pre_%s.csv', datestr(now, 'yyyymmdd_HHMMSS')));
        movefile(logFile, archiveFile);
        fprintf('Log schema changed since the last run -- archived old log to:\n  %s\n', archiveFile);
        fprintf('Starting a fresh log with the current columns.\n');
    end
end

if ~isfile(logFile)
    fid = fopen(logFile, 'w');
    fprintf(fid, '%s\n', strjoin(headerRow, ','));
    fclose(fid);
end

fid = fopen(logFile, 'a');
rowStrs = cell(size(newRow));
for k = 1:numel(newRow)
    v = newRow{k};
    if ischar(v)
        % escape any commas inside notes
        v = strrep(v, ',', ';');
        rowStrs{k} = v;
    else
        rowStrs{k} = num2str(v);
    end
end
fprintf(fid, '%s\n', strjoin(rowStrs, ','));
fclose(fid);

fprintf('Row appended to log: %s\n', logFile);

%% ---- 9. Quick plots from the log + this run's hotspot map -------------

logData = readtable(logFile);

fig = figure('Name', 'Haze Season Tracker', 'Color', 'w', 'Position', [100 100 1100 800]);

% Top panel: the same run summary printed to the console, reproduced
% verbatim in the figure so a saved PNG is self-contained.
summaryLines = {
    sprintf('========== SUPER EL-NINO, FIRE AND PRECIPITATION TRACKER -- %s ==========', runDate)
    sprintf('ONI / Nino 3.4 anomaly   : %+.2f degC  (%s)', oniValue, oniSeason)
    sprintf('Fire detections (%d d)   : %d', firmsDayRange, numel(fireLatMap))
    sprintf('Precip anomaly           : %+.0f %%   %s', precipAnomalyPct, precipNote)
    sprintf('Note                     : %s', campaignNote1)
    sprintf('                           %s', campaignNote2)
    sprintf('Plain language           : %s', plainLanguage1)
    sprintf('                           %s', plainLanguage2)
    '===================================================='
    };

subplot(3, 2, [1 2]);
axis off;
text(0, 1, strjoin(summaryLines, newline), ...
    'FontName', 'Courier New', 'FontSize', 10, ...
    'VerticalAlignment', 'top', 'HorizontalAlignment', 'left', ...
    'Units', 'normalized', 'Interpreter', 'none');
xlim([0 1]); ylim([0 1]);

% Bottom-left panel: rolling 1-year ONI window (from NOAA's own history,
% not dependent on how many times you've run this script) vs 2015-16 /
% 1997-98 analogs
subplot(3, 2, [3 5]);
if numel(oniTrendValue) >= 2 && any(~isnan(oniTrendValue))
    plot(oniTrendDate, oniTrendValue, '-o', ...
        'LineWidth', 1.5, 'MarkerFaceColor', [0.71 0.32 0.12]);
    hold on;
    yline(2.6, '--', '2015-16 peak (+2.6C)', 'Color', [0.55 0.5 0.4]);
    yline(2.0, ':', 'Very strong threshold (+2.0C)', 'Color', [0.55 0.5 0.4]);
    hold off;
    datetick('x', 'mmm yy');
    xlabel('Season (3-mo running mean)');
    ylabel('ONI anomaly (degC)');
    title('ONI, rolling 1-year window vs. super El Nino analogs');
    grid on;
else
    text(0.5, 0.5, 'Could not pull ONI trailing history this run', ...
        'HorizontalAlignment', 'center');
    axis off;
    title('ONI trend (unavailable)');
end

% Bottom-right panel: fire hotspots across all of Southeast Asia
subplot(3, 2, [4 6]);
if ~isempty(fireLatMap)
    geoscatter(fireLatMap, fireLonMap, 15, [0.71 0.32 0.12], 'filled');
    geolimits([firmsMapBBox(2) firmsMapBBox(4)], [firmsMapBBox(1) firmsMapBBox(3)]);
    geobasemap('grayland');
    title(sprintf('SE Asia fire hotspots, last %d day(s) (n=%d)', firmsDayRange, numel(fireLatMap)));
else
    text(0.5, 0.5, 'No fire detections this run', 'HorizontalAlignment', 'center');
    axis off;
    title('Fire hotspots');
end

%% ---- 10. Save the figure as PNG -----------------------------------------

figDir = fileparts(logFile);
if isempty(figDir)
    figDir = pwd;
end
figFile = fullfile(figDir, sprintf('haze_tracker_%s_SEAsia.png', runDate));

try
    print(fig, figFile, '-dpng', '-r150');
    fprintf('Figure saved to: %s\n', figFile);
catch ME
    warning('Could not save figure PNG: %s', ME.message);
end
