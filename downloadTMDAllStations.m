% downloadTMDAllStations.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% TSRI ST 2571, Activity 1 prototype -- TMD weather observations, all of Thailand.
%
% Same source as downloadWeatherAirQuality.m (SOURCE 3), extended from
% Chiang Mai to all 77 provinces:
%   GET https://www.tmd.go.th/api/weather/get-aws-weather-by-province?province=<Thai name, URL-encoded>
%   Open endpoint behind tmd.go.th's province pages; no API key; returns the
%   current reading of every automatic weather station in the province.
%   Province names are pre-encoded (as in the reference script) to avoid
%   MATLAB UTF-8 encoding issues.
%
% Snapshot-only endpoint, so the archive is built by polling: hourly at
% MINUTE_PAST_HOUR, a reading is kept when it is newer than the last one
% saved for that station.
%
% RUNS IN THE BACKGROUND (RUN_IN_BACKGROUND = true). TO STOP: stopPlatformTimers
%
% OUTPUTS (in outputDir)
%   TMD_AWS_YYYYMM.csv     archive, one row per station reading (local time)
%   TMD_AWS_latest.csv     newest reading of every station (overwritten each poll);
%                          also the station list for the forecast extraction
%   lastState_TmdAll.mat, download_log.txt
%
% Columns: stationId, nameEn, province, lat, lon, dateTimeLocal, temperature (degC),
%   humidity (%), windSpeed, windDirection (deg), precip1Hr (mm), precipToday (mm),
%   pressure (hPa), temperatureMinToday, temperatureMaxToday
%   windSpeed is stored as TMD reports it. Set TMD_WIND_TO_MS in
%   exportDashboardData.m to match (1 if TMD reports m/s, 1/3.6 if km/h).

clear; clc;
%% ============================ CONFIG =======================================
cfg.apiURL = 'https://www.tmd.go.th/api/weather/get-aws-weather-by-province';

% English name | URL-encoded Thai name (UTF-8 percent-encoding)
cfg.provinces = {
    'Bangkok', '%E0%B8%81%E0%B8%A3%E0%B8%B8%E0%B8%87%E0%B9%80%E0%B8%97%E0%B8%9E%E0%B8%A1%E0%B8%AB%E0%B8%B2%E0%B8%99%E0%B8%84%E0%B8%A3';  % กรุงเทพมหานคร
    'Krabi', '%E0%B8%81%E0%B8%A3%E0%B8%B0%E0%B8%9A%E0%B8%B5%E0%B9%88';  % กระบี่
    'Kanchanaburi', '%E0%B8%81%E0%B8%B2%E0%B8%8D%E0%B8%88%E0%B8%99%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % กาญจนบุรี
    'Kalasin', '%E0%B8%81%E0%B8%B2%E0%B8%AC%E0%B8%AA%E0%B8%B4%E0%B8%99%E0%B8%98%E0%B8%B8%E0%B9%8C';  % กาฬสินธุ์
    'Kamphaeng Phet', '%E0%B8%81%E0%B8%B3%E0%B9%81%E0%B8%9E%E0%B8%87%E0%B9%80%E0%B8%9E%E0%B8%8A%E0%B8%A3';  % กำแพงเพชร
    'Khon Kaen', '%E0%B8%82%E0%B8%AD%E0%B8%99%E0%B9%81%E0%B8%81%E0%B9%88%E0%B8%99';  % ขอนแก่น
    'Chanthaburi', '%E0%B8%88%E0%B8%B1%E0%B8%99%E0%B8%97%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % จันทบุรี
    'Chachoengsao', '%E0%B8%89%E0%B8%B0%E0%B9%80%E0%B8%8A%E0%B8%B4%E0%B8%87%E0%B9%80%E0%B8%97%E0%B8%A3%E0%B8%B2';  % ฉะเชิงเทรา
    'Chon Buri', '%E0%B8%8A%E0%B8%A5%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % ชลบุรี
    'Chai Nat', '%E0%B8%8A%E0%B8%B1%E0%B8%A2%E0%B8%99%E0%B8%B2%E0%B8%97';  % ชัยนาท
    'Chaiyaphum', '%E0%B8%8A%E0%B8%B1%E0%B8%A2%E0%B8%A0%E0%B8%B9%E0%B8%A1%E0%B8%B4';  % ชัยภูมิ
    'Chumphon', '%E0%B8%8A%E0%B8%B8%E0%B8%A1%E0%B8%9E%E0%B8%A3';  % ชุมพร
    'Chiang Rai', '%E0%B9%80%E0%B8%8A%E0%B8%B5%E0%B8%A2%E0%B8%87%E0%B8%A3%E0%B8%B2%E0%B8%A2';  % เชียงราย
    'Chiang Mai', '%E0%B9%80%E0%B8%8A%E0%B8%B5%E0%B8%A2%E0%B8%87%E0%B9%83%E0%B8%AB%E0%B8%A1%E0%B9%88';  % เชียงใหม่
    'Trang', '%E0%B8%95%E0%B8%A3%E0%B8%B1%E0%B8%87';  % ตรัง
    'Trat', '%E0%B8%95%E0%B8%A3%E0%B8%B2%E0%B8%94';  % ตราด
    'Tak', '%E0%B8%95%E0%B8%B2%E0%B8%81';  % ตาก
    'Nakhon Nayok', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%99%E0%B8%B2%E0%B8%A2%E0%B8%81';  % นครนายก
    'Nakhon Pathom', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%9B%E0%B8%90%E0%B8%A1';  % นครปฐม
    'Nakhon Phanom', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%9E%E0%B8%99%E0%B8%A1';  % นครพนม
    'Nakhon Ratchasima', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%A3%E0%B8%B2%E0%B8%8A%E0%B8%AA%E0%B8%B5%E0%B8%A1%E0%B8%B2';  % นครราชสีมา
    'Nakhon Si Thammarat', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%A8%E0%B8%A3%E0%B8%B5%E0%B8%98%E0%B8%A3%E0%B8%A3%E0%B8%A1%E0%B8%A3%E0%B8%B2%E0%B8%8A';  % นครศรีธรรมราช
    'Nakhon Sawan', '%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%AA%E0%B8%A7%E0%B8%A3%E0%B8%A3%E0%B8%84%E0%B9%8C';  % นครสวรรค์
    'Nonthaburi', '%E0%B8%99%E0%B8%99%E0%B8%97%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % นนทบุรี
    'Narathiwat', '%E0%B8%99%E0%B8%A3%E0%B8%B2%E0%B8%98%E0%B8%B4%E0%B8%A7%E0%B8%B2%E0%B8%AA';  % นราธิวาส
    'Nan', '%E0%B8%99%E0%B9%88%E0%B8%B2%E0%B8%99';  % น่าน
    'Bueng Kan', '%E0%B8%9A%E0%B8%B6%E0%B8%87%E0%B8%81%E0%B8%B2%E0%B8%AC';  % บึงกาฬ
    'Buri Ram', '%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5%E0%B8%A3%E0%B8%B1%E0%B8%A1%E0%B8%A2%E0%B9%8C';  % บุรีรัมย์
    'Pathum Thani', '%E0%B8%9B%E0%B8%97%E0%B8%B8%E0%B8%A1%E0%B8%98%E0%B8%B2%E0%B8%99%E0%B8%B5';  % ปทุมธานี
    'Prachuap Khiri Khan', '%E0%B8%9B%E0%B8%A3%E0%B8%B0%E0%B8%88%E0%B8%A7%E0%B8%9A%E0%B8%84%E0%B8%B5%E0%B8%A3%E0%B8%B5%E0%B8%82%E0%B8%B1%E0%B8%99%E0%B8%98%E0%B9%8C';  % ประจวบคีรีขันธ์
    'Prachin Buri', '%E0%B8%9B%E0%B8%A3%E0%B8%B2%E0%B8%88%E0%B8%B5%E0%B8%99%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % ปราจีนบุรี
    'Pattani', '%E0%B8%9B%E0%B8%B1%E0%B8%95%E0%B8%95%E0%B8%B2%E0%B8%99%E0%B8%B5';  % ปัตตานี
    'Phra Nakhon Si Ayutthaya', '%E0%B8%9E%E0%B8%A3%E0%B8%B0%E0%B8%99%E0%B8%84%E0%B8%A3%E0%B8%A8%E0%B8%A3%E0%B8%B5%E0%B8%AD%E0%B8%A2%E0%B8%B8%E0%B8%98%E0%B8%A2%E0%B8%B2';  % พระนครศรีอยุธยา
    'Phayao', '%E0%B8%9E%E0%B8%B0%E0%B9%80%E0%B8%A2%E0%B8%B2';  % พะเยา
    'Phangnga', '%E0%B8%9E%E0%B8%B1%E0%B8%87%E0%B8%87%E0%B8%B2';  % พังงา
    'Phatthalung', '%E0%B8%9E%E0%B8%B1%E0%B8%97%E0%B8%A5%E0%B8%B8%E0%B8%87';  % พัทลุง
    'Phichit', '%E0%B8%9E%E0%B8%B4%E0%B8%88%E0%B8%B4%E0%B8%95%E0%B8%A3';  % พิจิตร
    'Phitsanulok', '%E0%B8%9E%E0%B8%B4%E0%B8%A9%E0%B8%93%E0%B8%B8%E0%B9%82%E0%B8%A5%E0%B8%81';  % พิษณุโลก
    'Phetchaburi', '%E0%B9%80%E0%B8%9E%E0%B8%8A%E0%B8%A3%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % เพชรบุรี
    'Phetchabun', '%E0%B9%80%E0%B8%9E%E0%B8%8A%E0%B8%A3%E0%B8%9A%E0%B8%B9%E0%B8%A3%E0%B8%93%E0%B9%8C';  % เพชรบูรณ์
    'Phrae', '%E0%B9%81%E0%B8%9E%E0%B8%A3%E0%B9%88';  % แพร่
    'Phuket', '%E0%B8%A0%E0%B8%B9%E0%B9%80%E0%B8%81%E0%B9%87%E0%B8%95';  % ภูเก็ต
    'Maha Sarakham', '%E0%B8%A1%E0%B8%AB%E0%B8%B2%E0%B8%AA%E0%B8%B2%E0%B8%A3%E0%B8%84%E0%B8%B2%E0%B8%A1';  % มหาสารคาม
    'Mukdahan', '%E0%B8%A1%E0%B8%B8%E0%B8%81%E0%B8%94%E0%B8%B2%E0%B8%AB%E0%B8%B2%E0%B8%A3';  % มุกดาหาร
    'Mae Hong Son', '%E0%B9%81%E0%B8%A1%E0%B9%88%E0%B8%AE%E0%B9%88%E0%B8%AD%E0%B8%87%E0%B8%AA%E0%B8%AD%E0%B8%99';  % แม่ฮ่องสอน
    'Yasothon', '%E0%B8%A2%E0%B9%82%E0%B8%AA%E0%B8%98%E0%B8%A3';  % ยโสธร
    'Yala', '%E0%B8%A2%E0%B8%B0%E0%B8%A5%E0%B8%B2';  % ยะลา
    'Roi Et', '%E0%B8%A3%E0%B9%89%E0%B8%AD%E0%B8%A2%E0%B9%80%E0%B8%AD%E0%B9%87%E0%B8%94';  % ร้อยเอ็ด
    'Ranong', '%E0%B8%A3%E0%B8%B0%E0%B8%99%E0%B8%AD%E0%B8%87';  % ระนอง
    'Rayong', '%E0%B8%A3%E0%B8%B0%E0%B8%A2%E0%B8%AD%E0%B8%87';  % ระยอง
    'Ratchaburi', '%E0%B8%A3%E0%B8%B2%E0%B8%8A%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % ราชบุรี
    'Lop Buri', '%E0%B8%A5%E0%B8%9E%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % ลพบุรี
    'Lampang', '%E0%B8%A5%E0%B8%B3%E0%B8%9B%E0%B8%B2%E0%B8%87';  % ลำปาง
    'Lamphun', '%E0%B8%A5%E0%B8%B3%E0%B8%9E%E0%B8%B9%E0%B8%99';  % ลำพูน
    'Loei', '%E0%B9%80%E0%B8%A5%E0%B8%A2';  % เลย
    'Si Sa Ket', '%E0%B8%A8%E0%B8%A3%E0%B8%B5%E0%B8%AA%E0%B8%B0%E0%B9%80%E0%B8%81%E0%B8%A9';  % ศรีสะเกษ
    'Sakon Nakhon', '%E0%B8%AA%E0%B8%81%E0%B8%A5%E0%B8%99%E0%B8%84%E0%B8%A3';  % สกลนคร
    'Songkhla', '%E0%B8%AA%E0%B8%87%E0%B8%82%E0%B8%A5%E0%B8%B2';  % สงขลา
    'Satun', '%E0%B8%AA%E0%B8%95%E0%B8%B9%E0%B8%A5';  % สตูล
    'Samut Prakan', '%E0%B8%AA%E0%B8%A1%E0%B8%B8%E0%B8%97%E0%B8%A3%E0%B8%9B%E0%B8%A3%E0%B8%B2%E0%B8%81%E0%B8%B2%E0%B8%A3';  % สมุทรปราการ
    'Samut Songkhram', '%E0%B8%AA%E0%B8%A1%E0%B8%B8%E0%B8%97%E0%B8%A3%E0%B8%AA%E0%B8%87%E0%B8%84%E0%B8%A3%E0%B8%B2%E0%B8%A1';  % สมุทรสงคราม
    'Samut Sakhon', '%E0%B8%AA%E0%B8%A1%E0%B8%B8%E0%B8%97%E0%B8%A3%E0%B8%AA%E0%B8%B2%E0%B8%84%E0%B8%A3';  % สมุทรสาคร
    'Sa Kaeo', '%E0%B8%AA%E0%B8%A3%E0%B8%B0%E0%B9%81%E0%B8%81%E0%B9%89%E0%B8%A7';  % สระแก้ว
    'Saraburi', '%E0%B8%AA%E0%B8%A3%E0%B8%B0%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % สระบุรี
    'Sing Buri', '%E0%B8%AA%E0%B8%B4%E0%B8%87%E0%B8%AB%E0%B9%8C%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % สิงห์บุรี
    'Sukhothai', '%E0%B8%AA%E0%B8%B8%E0%B9%82%E0%B8%82%E0%B8%97%E0%B8%B1%E0%B8%A2';  % สุโขทัย
    'Suphan Buri', '%E0%B8%AA%E0%B8%B8%E0%B8%9E%E0%B8%A3%E0%B8%A3%E0%B8%93%E0%B8%9A%E0%B8%B8%E0%B8%A3%E0%B8%B5';  % สุพรรณบุรี
    'Surat Thani', '%E0%B8%AA%E0%B8%B8%E0%B8%A3%E0%B8%B2%E0%B8%A9%E0%B8%8E%E0%B8%A3%E0%B9%8C%E0%B8%98%E0%B8%B2%E0%B8%99%E0%B8%B5';  % สุราษฎร์ธานี
    'Surin', '%E0%B8%AA%E0%B8%B8%E0%B8%A3%E0%B8%B4%E0%B8%99%E0%B8%97%E0%B8%A3%E0%B9%8C';  % สุรินทร์
    'Nong Khai', '%E0%B8%AB%E0%B8%99%E0%B8%AD%E0%B8%87%E0%B8%84%E0%B8%B2%E0%B8%A2';  % หนองคาย
    'Nong Bua Lam Phu', '%E0%B8%AB%E0%B8%99%E0%B8%AD%E0%B8%87%E0%B8%9A%E0%B8%B1%E0%B8%A7%E0%B8%A5%E0%B8%B3%E0%B8%A0%E0%B8%B9';  % หนองบัวลำภู
    'Ang Thong', '%E0%B8%AD%E0%B9%88%E0%B8%B2%E0%B8%87%E0%B8%97%E0%B8%AD%E0%B8%87';  % อ่างทอง
    'Amnat Charoen', '%E0%B8%AD%E0%B8%B3%E0%B8%99%E0%B8%B2%E0%B8%88%E0%B9%80%E0%B8%88%E0%B8%A3%E0%B8%B4%E0%B8%8D';  % อำนาจเจริญ
    'Udon Thani', '%E0%B8%AD%E0%B8%B8%E0%B8%94%E0%B8%A3%E0%B8%98%E0%B8%B2%E0%B8%99%E0%B8%B5';  % อุดรธานี
    'Uttaradit', '%E0%B8%AD%E0%B8%B8%E0%B8%95%E0%B8%A3%E0%B8%94%E0%B8%B4%E0%B8%95%E0%B8%96%E0%B9%8C';  % อุตรดิตถ์
    'Uthai Thani', '%E0%B8%AD%E0%B8%B8%E0%B8%97%E0%B8%B1%E0%B8%A2%E0%B8%98%E0%B8%B2%E0%B8%99%E0%B8%B5';  % อุทัยธานี
    'Ubon Ratchathani', '%E0%B8%AD%E0%B8%B8%E0%B8%9A%E0%B8%A5%E0%B8%A3%E0%B8%B2%E0%B8%8A%E0%B8%98%E0%B8%B2%E0%B8%99%E0%B8%B5';  % อุบลราชธานี
    };

cfg.outputDir = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform/TMD_AWS_Archive';

cfg.RUN_IN_BACKGROUND   = true;
cfg.MINUTE_PAST_HOUR    = 2;      % just after the hour, so readings sit near HH:00
cfg.PAUSE_SEC           = 0.3;    % pause between province requests
cfg.REQUEST_TIMEOUT_SEC = 30;
% ===========================================================================

if ~exist(cfg.outputDir, 'dir')
    mkdir(cfg.outputDir);
end
cfg.logFile = fullfile(cfg.outputDir, 'download_log.txt');

timerName = 'TMDAllStationsTimer';
existingTimer = timerfind('Name', timerName);
if ~isempty(existingTimer)
    fprintf('A TMD all-stations timer is already running. Stopping and replacing it.\n');
    stop(existingTimer);
    delete(existingTimer);
end

runTmdCycleSafe(cfg);

if cfg.RUN_IN_BACKGROUND
    nowLocal = datetime('now', 'TimeZone', 'local');
    nextRun  = dateshift(nowLocal, 'start', 'hour') + minutes(cfg.MINUTE_PAST_HOUR);
    if nextRun <= nowLocal
        nextRun = nextRun + hours(1);
    end
    startDelaySec = max(1, round(seconds(nextRun - nowLocal)));

    tmdTimer = timer( ...
        'Name', timerName, ...
        'ExecutionMode', 'fixedRate', ...
        'Period', 3600, ...
        'StartDelay', startDelaySec, ...
        'BusyMode', 'drop', ...
        'TimerFcn', @(~,~) runTmdCycleSafe(cfg), ...
        'ErrorFcn', @(~,evt) fprintf('TMD timer error: %s\n', evt.Data.message));
    start(tmdTimer);

    fprintf('\nTMD all-stations downloader is now running in the background.\n');
    fprintf('Hourly at :%02d (next run in %.0f seconds).\n', cfg.MINUTE_PAST_HOUR, startDelaySec);
    fprintf('To stop it, run:  stopPlatformTimers\n\n');
end


%% ============================ LOCAL FUNCTIONS ===============================

function runTmdCycleSafe(cfg)
try
    runTmdCycle(cfg);
catch ME
    fprintf('[%s] TMD cycle failed: %s\n', datestr(now), ME.message);
    writeLog(cfg.logFile, sprintf('%s | ERROR | cycle failed: %s', datestr(now), ME.message));
end
end


function runTmdCycle(cfg)
fprintf('[%s] Polling TMD AWS in %d provinces...\n', datestr(now), size(cfg.provinces, 1));
opts = weboptions('ContentType', 'text', 'Timeout', cfg.REQUEST_TIMEOUT_SEC, 'CertificateFilename', '');

numCols = {'lat', 'lon', 'temperature', 'humidity', 'windSpeed', 'windDirection', 'precip1Hr', ...
           'precipToday', 'pressure', 'temperatureMinToday', 'temperatureMaxToday'};
apiNum  = {'stationLat', 'stationLon', 'temperature', 'humidity', 'windSpeed', 'windDirection', 'precip1Hr', ...
           'precipToday', 'pressure', 'temperatureMinToday', 'temperatureMaxToday'};

ids = {}; names = {}; provs = {}; times = {}; vals = zeros(0, numel(numCols));
failed = {};
for p = 1:size(cfg.provinces, 1)
    try
        raw  = webread(sprintf('%s?province=%s', cfg.apiURL, cfg.provinces{p, 2}), opts);
        data = jsondecode(raw);
    catch ME
        failed{end+1} = sprintf('%s (%s)', cfg.provinces{p, 1}, ME.message); %#ok<AGROW>
        pause(cfg.PAUSE_SEC);
        continue;
    end
    if ~isfield(data, 'success') || ~data.success || ~isfield(data, 'data') || isempty(data.data)
        failed{end+1} = sprintf('%s (empty response)', cfg.provinces{p, 1}); %#ok<AGROW>
        pause(cfg.PAUSE_SEC);
        continue;
    end
    st = data.data;
    if isstruct(st)
        st = num2cell(st);
    end
    for i = 1:numel(st)
        rec = st{i};
        idNum = getNum(rec, 'stationId');
        tStr  = getStr(rec, 'dateTimeUtc7');
        if isnan(idNum) || numel(tStr) < 19
            continue;
        end
        ids{end+1, 1}   = sprintf('%d', idNum);                   %#ok<AGROW>
        names{end+1, 1} = getStr(rec, 'stationNameEn');           %#ok<AGROW>
        provs{end+1, 1} = cfg.provinces{p, 1};                    %#ok<AGROW>
        times{end+1, 1} = strrep(tStr(1:19), 'T', ' ');           %#ok<AGROW>  local time (UTC+7)
        v = nan(1, numel(numCols));
        for c = 1:numel(numCols)
            v(c) = getNum(rec, apiNum{c});
        end
        vals(end+1, :) = v;                                       %#ok<AGROW>
    end
    pause(cfg.PAUSE_SEC);
end

if isempty(ids)
    % Include the first province's actual error, so the log shows the cause
    firstErr = '';
    if ~isempty(failed), firstErr = sprintf(' First failure: %s', failed{1}); end
    msg = sprintf('No TMD stations returned (%d provinces failed).%s', numel(failed), firstErr);
    writeLog(cfg.logFile, sprintf('%s | ERROR | %s', datestr(now), msg));
    error(msg); %#ok<SPERR>
end

% A station listed under two provinces is kept once
[~, ia] = unique(ids, 'stable');
ids = ids(ia); names = names(ia); provs = provs(ia); times = times(ia); vals = vals(ia, :);
t = datetime(times, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');

% --- Latest snapshot (overwritten) ---
writeRows(fullfile(cfg.outputDir, 'TMD_AWS_latest.csv'), 'w', ids, names, provs, times, vals, numCols);

% --- New readings only, appended to the month of the reading ---
stateFile = fullfile(cfg.outputDir, 'lastState_TmdAll.mat');
lastIds = {}; lastT = NaT(0, 1);
if exist(stateFile, 'file')
    S = load(stateFile);
    if isfield(S, 'lastIds'), lastIds = S.lastIds; lastT = S.lastT; end
end
[known, loc] = ismember(ids, lastIds);
isNew = ~known;
isNew(known) = t(known) > lastT(loc(known));
nNew = sum(isNew);

if nNew > 0
    ym = year(t) * 100 + month(t);
    for m = unique(ym(isNew))'
        sel = isNew & ym == m;
        fn = fullfile(cfg.outputDir, sprintf('TMD_AWS_%d.csv', m));
        writeRows(fn, 'a', ids(sel), names(sel), provs(sel), times(sel), vals(sel, :), numCols);
    end
end

% State: newest saved time per station
allIds = [lastIds(:); ids(isNew)];
allT   = [lastT(:);   t(isNew)];
[lastIds, ~, g] = unique(allIds);
lastT = NaT(numel(lastIds), 1);
for k = 1:numel(lastIds)
    lastT(k) = max(allT(g == k));
end
save(stateFile, 'lastIds', 'lastT');

msg = sprintf('%s | stations=%d | new readings=%d | provinces failed=%d', ...
    datestr(now), numel(ids), nNew, numel(failed));
if ~isempty(failed)
    msg = [msg ' (' strjoin(failed, '; ') ')'];
end
writeLog(cfg.logFile, msg);
fprintf('[%s] TMD: %d stations, %d new readings, %d province(s) failed.\n', ...
    datestr(now), numel(ids), nNew, numel(failed));
if ~isempty(failed)
    fprintf('  failed: %s\n', strjoin(failed, '; '));
end
end


function writeRows(fn, mode, ids, names, provs, times, vals, numCols)
% Writes (mode 'w') or appends (mode 'a') rows; header added to a new file.
newFile = ~exist(fn, 'file') || strcmp(mode, 'w');
fid = fopen(fn, mode, 'n', 'UTF-8');
if fid == -1
    error('Cannot open %s', fn);
end
if newFile
    fprintf(fid, '%s\n', strjoin([{'stationId', 'nameEn', 'province'}, numCols(1:2), ...
        {'dateTimeLocal'}, numCols(3:end)], ','));
end
for i = 1:numel(ids)
    v = vals(i, :);
    numStr = arrayfun(@(x) numOrNaNStr(x), v, 'UniformOutput', false);
    fprintf(fid, '%s\n', strjoin([{ids{i}, csvQuote(names{i}), csvQuote(provs{i})}, numStr(1:2), ...
        {times{i}}, numStr(3:end)], ','));
end
fclose(fid);
end


function s = csvQuote(x)
s = ['"' strrep(char(x), '"', '""') '"'];
end


function s = numOrNaNStr(v)
if isnan(v)
    s = 'NaN';
else
    s = num2str(v, '%.6g');
end
end


function val = getStr(rec, name)
if isfield(rec, name) && ~isempty(rec.(name))
    val = char(rec.(name));
else
    val = '';
end
end


function val = getNum(rec, name)
% JSON null (decoded as []) and non-numeric text -> NaN
val = NaN;
if isfield(rec, name)
    v = rec.(name);
    if isempty(v)
        return;
    elseif isnumeric(v)
        val = double(v(1));
    else
        val = str2double(v);
    end
end
end


function writeLog(logFile, msg)
fid = fopen(logFile, 'a');
if fid ~= -1
    fprintf(fid, '%s\n', msg);
    fclose(fid);
end
end
