function processImgData(varargin)

varargin2V(varargin);
if exist('initials','var') && exist('mouse_num','var') && exist('date_num','var')
    defaultDir = ['\\research.files.med.harvard.edu\Neurobio\HarveyLab\Tier2\Shin\ShinDataAll\Imaging\',initials,sprintf('%03d',mouse_num),filesep,num2str(date_num),filesep];
else
    movDir = uigetdir('\\research.files.med.harvard.edu\Neurobio\HarveyLab\Tier2\Shin\ShinDataAll\Imaging\');
    defaultDir = [movDir,filesep];
end

if ~exist('FOV_list','var')
    % If FOV is not specified, apply motion correction to all FOVs
    a = dir([defaultDir,'FOV*.tif']);
    for i = 1:length(a)
        FOV(i) = str2double(a(i).name(4));
    end
    FOV_list = unique(FOV);
end

for fi = 1:length(FOV_list)
    
    if iscell(FOV_list)
        FOV_name = [initials,num2str(mouse_num),'_',num2str(date_num),'_',FOV_list{fi}];
    elseif ischar(FOV_list)
        FOV_name = [initials,num2str(mouse_num),'_',num2str(date_num),'_',FOV_list];
    else
        error('FOV_list must be a Cell')
    end
    
    % create obj
    obj = Acquisition2P(['FOV',FOV_name],@SK2Pinit,defaultDir);
    
    if ~exist('motionCorrectionFunction','var')
        % overwrite motion correction function
        switch mouse_num
            case {1,3,16}
                obj.motionCorrectionFunction = @withinFile_fullFrame_fft;
            case {9,13,15,20,22,23}
                obj.motionCorrectionFunction = @lucasKanade_affineReg;
        end
    else
        obj.motionCorrectionFunction = motionCorrectionFunction;
    end
    fprintf('motionCorrectionFunction:\t%s\n',func2str(obj.motionCorrectionFunction));
    
    % apply motion correction
    obj.motionCorrect;
    
    return
    [mov, scanImageMetadata] = obj.readRaw(1,'single');
    [movStruct, nSlices, nChannels] = parseScanimageTiff(mov, scanImageMetadata);
    
    if obj.motionCorrectionDone
        for si = 1:nSlices
            for ni = 1:nChannels
                sliceNum = si; %Choose a slice to analyze
                channelNum = ni; %Choose the GCaMP channel
                movNums = []; %this will default to all movie files
                radiusPxCov = 11; %default, may need zoom level adjustment
                temporalBin = 8; %default (tested w/ 15-30hz imaging), may need adjustment based on frame rate
                writeDir = []; %empty defaults to the directory the object is saved in (the 'defaultDir')

                obj.calcPxCov(movNums,radiusPxCov,temporalBin,sliceNum,channelNum,writeDir);
                obj.save;
                obj.indexMovie(sliceNum,channelNum,writeDir);
                obj.save;
                % Customized motion correction function
                computerName = getComputerName;
                switch computerName
                    case 'shin-pc'
                        % obj.indexMovie2(sliceNum,channelNum,writeDir);
                    case 'harveylab41223' 
                end
                obj.save
            end
        end
        %% copy auxiliary auxiliary files to the local HD
        sourceDir = obj.defaultDir;
        files2local = dir([sourceDir,obj.acqName,'*.h5']);
        files2local = [files2local;dir([sourceDir,obj.acqName,'*.bin'])];
        % files2server = dir([sourceDir,'Corrected',filesep,obj.acqName,'*.tif']);
        
        % configure file destinations
        ind = strfind(obj.defaultDir,obj.initials);
        localDir = ['C:\Users\Shin\Documents\MATLAB\ShinDataAll\Imaging\',obj.defaultDir(ind:end)];
        % serverDir = ['Z:\HarveyLab\Tier2\Shin\ShinDataAll\Imaging\',obj.defaultDir(ind:end)];
        
        if ~exist([localDir,'Corrected'],'dir')
            mkdir([localDir,'Corrected']);
        end
        for i = 1:length(files2local)
            copyfile([sourceDir,files2local(i).name],[localDir,files2local(i).name])
        end
        
        if 0 % skip this if motion correction is applied to files on the server
            % copy motion-corrected movies to the server
            if ~exist([serverDir,'Corrected'],'dir')
                mkdir([serverDir,'Corrected']);
            end
            for i = 1:length(files2server)
                copyfile([sourceDir,'Corrected',filesep,files2server(i).name],[serverDir,'Corrected',filesep,files2server(i).name])
            end
        end
        
    end
end

end