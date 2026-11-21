% checkPlatformMounts.m
%
% STANDALONE SCRIPT. MATLAB R2018b compatible (Linux).
% Checks the two mounts the platform depends on and repairs what it can:
%
%   1. Seagate drive (all archives and the dashboard live there).
%      Only checked, not mounted: if it is missing, plug it in / open it
%      in the file manager. pmDriveOK = false tells startPlatform to stop,
%      so nothing gets written to an empty /media folder by mistake.
%
%   2. HPC sshfs mount (WRF-Chem forecast output).
%      Tested by listing a folder with a 20 s timeout, so a dead mount
%      ("Transport endpoint is not connected") is caught too. If it fails,
%      the mount is detached and remounted as user arun, using arun's SSH
%      key (no password prompt; BatchMode makes it fail fast instead of
%      hanging if the key is missing).
%
% Called by startPlatform at startup and by the MountWatchdogTimer every
% 15 minutes. Prints nothing when both mounts are fine.
%
% Sets in the workspace: pmDriveOK, pmHpcOK (true/false)
%
% ONE-TIME SETUP (in a terminal, as arun -- NOT with sudo):
%   ssh-keygen -t ed25519            (press Enter at every prompt)
%   ssh-copy-id ronald@192.168.5.201
%   sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf   (already done)

pmDriveDir    = '/media/arun/Seagate Backup Plus Drive/TSRI_ST_71/Activity1_Platform';
pmMountPoint  = '/home/arun/HPC';
pmRemote      = 'ronald@192.168.5.201:/ltzfs/ARUN/';
pmTestDir     = '/home/arun/HPC/Projects/NARITForecastingSystem';
pmLocalUser   = 'arun';
pmSshfsOpts   = 'allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,BatchMode=yes,ConnectTimeout=10';

%% 1. Seagate drive
pmDriveOK = exist(pmDriveDir, 'dir') == 7;
if ~pmDriveOK
    fprintf(2, '[%s] Seagate drive not found: %s -- plug it in or open it in the file manager.\n', ...
        datestr(now), pmDriveDir);
end

%% 2. HPC mount
[pmStatus, ~] = system(sprintf('timeout 20 ls -d "%s" > /dev/null 2>&1', pmTestDir));
pmHpcOK = (pmStatus == 0);

if ~pmHpcOK
    fprintf('[%s] HPC mount not responding -- remounting...\n', datestr(now));

    % Mount as arun even when MATLAB runs as root, so arun's SSH key is used
    [~, pmWho] = system('whoami');
    if strcmp(strtrim(pmWho), pmLocalUser)
        pmAs = '';
    else
        pmAs = ['sudo -u ' pmLocalUser ' '];
    end

    % Detach whatever is left of the old mount (lazy, works even if busy)
    system(sprintf('%sfusermount -uz "%s" > /dev/null 2>&1', pmAs, pmMountPoint));
    system(sprintf('umount -l "%s" > /dev/null 2>&1', pmMountPoint));

    [~, pmOut] = system(sprintf('%ssshfs -o %s %s "%s" 2>&1', pmAs, pmSshfsOpts, pmRemote, pmMountPoint));
    pause(2);
    [pmStatus, ~] = system(sprintf('timeout 20 ls -d "%s" > /dev/null 2>&1', pmTestDir));
    pmHpcOK = (pmStatus == 0);

    if pmHpcOK
        pmMsg = sprintf('%s | HPC mount was down -- remounted OK', datestr(now));
        fprintf('[%s] HPC remounted OK.\n', datestr(now));
    else
        pmMsg = sprintf('%s | HPC remount FAILED: %s', datestr(now), strtrim(pmOut));
        fprintf(2, '[%s] HPC remount failed: %s\n', datestr(now), strtrim(pmOut));
        if ~isempty(strfind(lower(pmOut), 'permission denied'))
            fprintf(2, '  -> SSH key not set up for %s. See ONE-TIME SETUP in checkPlatformMounts.m\n', pmLocalUser);
        end
    end

    if pmDriveOK
        pmFid = fopen(fullfile(pmDriveDir, 'mount_log.txt'), 'a');
        if pmFid ~= -1
            fprintf(pmFid, '%s\n', pmMsg);
            fclose(pmFid);
        end
    end
end
