% inspectWRFOutput.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible.
% One-off check of the operational WRF-Chem output, read over the sshfs
% mount. Finds the run folder automatically (today minus DAY_OFFSET days,
% e.g. 2026-10-13 on 15 Oct) and prints what is needed to write the
% forecast extraction script. Paste the printed output back.
%
% If that folder is missing or has no wrfout files yet (run still going),
% it falls back to the most recent dated folder that has wrfout files.

clear; clc;
%% ---- Settings ----
baseDir   = '/home/arun/HPC/Projects/NARITForecastingSystem/tes2';
DAY_OFFSET = 2;                 % run folder date = today - DAY_OFFSET
varsOfInterest = {'Times', 'XLAT', 'XLONG', 'PM2_5_DRY', 'PM10', 'PBLH', ...
    'T2', 'Q2', 'U10', 'V10', 'RAINNC', 'RAINC', 'PSFC', 'HGT', 'CLDFRA'};
attsOfInterest = {'TITLE', 'START_DATE', 'SIMULATION_START_DATE', 'DX', 'DY', ...
    'MAP_PROJ', 'CEN_LAT', 'CEN_LON', 'TRUELAT1', 'TRUELAT2', 'STAND_LON', ...
    'CHEM_OPT', 'BL_PBL_PHYSICS', 'MP_PHYSICS', 'CU_PHYSICS', 'GRID_ID'};

%% ---- 1. Find the run folder ----
if ~exist(baseDir, 'dir')
    error('Base folder not found: %s -- is the HPC mounted (sshfs)?', baseDir);
end

today   = dateshift(datetime('now', 'TimeZone', 'Asia/Bangkok'), 'start', 'day');
runDate = today - days(DAY_OFFSET);
runDir  = fullfile(baseDir, datestr(runDate, 'yyyy-mm-dd'));
fprintf('Expected run folder (today - %d d): %s\n', DAY_OFFSET, runDir);

if ~exist(runDir, 'dir') || isempty(dir(fullfile(runDir, 'wrfout*')))
    fprintf('  -> missing or no wrfout files yet; looking for the latest complete folder...\n');
    d = dir(baseDir);
    d = d([d.isdir]);
    names = {d.name};
    names = names(~cellfun(@isempty, regexp(names, '^\d{4}-\d{2}-\d{2}$', 'once')));
    names = sort(names);
    runDir = '';
    for k = numel(names):-1:1
        cand = fullfile(baseDir, names{k});
        if ~isempty(dir(fullfile(cand, 'wrfout*')))
            runDir = cand;
            break;
        end
    end
    if isempty(runDir)
        error('No dated folder with wrfout files found in %s', baseDir);
    end
    fprintf('  -> using %s\n', runDir);
end

%% ---- 2. File list ----
files = dir(fullfile(runDir, 'wrfout*'));
fprintf('\n%d wrfout file(s) in %s\n', numel(files), runDir);
for k = 1:numel(files)
    fprintf('  %-45s %8.1f MB  %s\n', files(k).name, files(k).bytes / 1e6, files(k).date);
end

%% ---- 3. Header of the first file ----
f = fullfile(runDir, files(1).name);
info = ncinfo(f);
fprintf('\n=== %s ===\nFormat: %s\n', files(1).name, info.Format);

fprintf('\nDimensions:\n');
for k = 1:numel(info.Dimensions)
    fprintf('  %-22s %d\n', info.Dimensions(k).Name, info.Dimensions(k).Length);
end

fprintf('\nVariables of interest:\n');
allVars = {info.Variables.Name};
for k = 1:numel(varsOfInterest)
    i = find(strcmp(allVars, varsOfInterest{k}), 1);
    if isempty(i)
        fprintf('  %-10s NOT FOUND\n', varsOfInterest{k});
        continue;
    end
    V = info.Variables(i);
    units = ''; desc = '';
    if ~isempty(V.Attributes)
        an = {V.Attributes.Name};
        j = find(strcmp(an, 'units'), 1);       if ~isempty(j), units = V.Attributes(j).Value; end
        j = find(strcmp(an, 'description'), 1); if ~isempty(j), desc  = V.Attributes(j).Value; end
    end
    fprintf('  %-10s [%s]  %s  -- %s\n', V.Name, num2str(V.Size), units, desc);
end

% Other chemistry/aerosol variables, in case PM2.5 is named differently
chemLike = allVars(~cellfun(@isempty, regexpi(allVars, '^(PM|so4|nh4|no3|oc|bc|smoke|tr17|co$|o3$)', 'once')));
fprintf('\nOther PM/chemistry-like variables: %s\n', strjoin(chemLike, ', '));
fprintf('Total variables in file: %d\n', numel(allVars));

fprintf('\nGlobal attributes:\n');
gn = {info.Attributes.Name};
for k = 1:numel(attsOfInterest)
    j = find(strcmp(gn, attsOfInterest{k}), 1);
    if ~isempty(j)
        val = info.Attributes(j).Value;
        if isnumeric(val), val = num2str(val); end
        fprintf('  %-22s %s\n', attsOfInterest{k}, val);
    end
end

%% ---- 4. Time coverage and domain ----
t1 = ncread(f, 'Times')';
fprintf('\nTimes in first file: %d (%s to %s)\n', size(t1, 1), strtrim(t1(1, :)), strtrim(t1(end, :)));
if numel(files) > 1
    tN = ncread(fullfile(runDir, files(end).name), 'Times')';
    fprintf('Last file: %s to %s\n', strtrim(tN(1, :)), strtrim(tN(end, :)));
end

lat = ncread(f, 'XLAT',  [1 1 1], [Inf Inf 1]);
lon = ncread(f, 'XLONG', [1 1 1], [Inf Inf 1]);
fprintf('Domain: lat %.2f to %.2f, lon %.2f to %.2f\n', min(lat(:)), max(lat(:)), min(lon(:)), max(lon(:)));
