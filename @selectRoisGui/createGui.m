function createGui(sel, acq, img, sliceNum, channelNum, smoothWindow, excludeFrames)
% Constructor method for the selectRoisGui class. See selectROIs.m for
% usage.

%% Create GUI data structure:
% Initialize properties:
sel.acq = acq;
sel.slice = sliceNum;

% Set up roiInfo: The roiInfo property of the sel object automatically
% points to the acq object, so whatever we do
if ~isfield(sel.roiInfo, 'roiList') || isempty(sel.roiInfo.roiList)
    % If this is acq object has not been processed before, initialize
    % fields:
    sel.roiInfo.hasBeenViewed = zeros(size(img));
    sel.roiInfo.roiLabels = zeros(size(img));
    sel.roiInfo.roiList = [];
    sel.roiInfo.grouping = [];
    sel.roiInfo.roi = struct();
end

sel.roiInfo.roiList = unique(sel.roiInfo.roiLabels(:));

% Set the current ROI to be 1 greater than last selected
sel.disp.currentRoi = max(sel.roiInfo.roiList)+1;
sel.roiInfo.roiList(sel.roiInfo.roiList==0) = [];

% Initialize data/settings for display:
sel.disp.clusterNum = 3; % Initial number of cuts.
sel.disp.currentClustering = zeros(sel.roiInfo.covFile.nh); % Labels of current clusters.
sel.disp.currentClustInd = []; % Which cluster/Roi is currently selected.
sel.disp.cutVecs = [];
sel.disp.roiMask = [];
sel.disp.indBody = [];
sel.disp.indNeuropil = [];
sel.disp.neuropilCoef = [];
sel.disp.smoothWindow = smoothWindow;
sel.disp.currentPos = [nan nan]; % Makes current click/focus position available across functions.
sel.disp.movSize = size(img);
sel.disp.excludeFrames = excludeFrames; % Frames in the traces that are to be excluded from neuropil calculations, e.g. due to stim artefacts.
sel.disp.roiColors =  [0 0 1;...
    1 0 0;
    0 1 0;...
    0 0 0.172413793103448;...
    1 0.103448275862069 0.724137931034483;...
    1 0.827586206896552 0;...
    0 0.344827586206897 0;...
    0.517241379310345 0.517241379310345 1;...
    0.620689655172414 0.310344827586207 0.275862068965517];

% Create overview image:
img = imadjust(img);
useActImg = false;
if useActImg
    img = repmat(img, 1, 1, 3);
    actImg = imadjust(adapthisteq(mat2gray(sel.roiInfo.covFile.activityImg), 'cliplim', 0.03, 'numtiles', [50 50]));
    img(:,:,2) = actImg;
    img(:,:,3) = 0;
end
sel.disp.img = img;

% Create memory map of pixCov file:
sel.covMap = memmapfile(sel.roiInfo.covFile.fileName, ...
    'format', {'single', [sel.roiInfo.covFile.nPix, sel.roiInfo.covFile.nDiags], 'pixCov'});

% Create memory mapped binary file of movie:
movSizes = [sel.acq.derivedData.size];
movLengths = movSizes(3:3:end);
sel.movMap = memmapfile(acq.indexedMovie.slice(sliceNum).channel(channelNum).fileName,...
    'Format', {'int16', [sum(movLengths), movSizes(1)*movSizes(2)], 'mov'});

%% Create GUI layout:
sel.h.fig.main = figure('Name','ROI Selection');
set(sel.h.fig.main, 'DefaultAxesFontSize', 10);

% Layout is based on screen orientation:
screenSize = get(0,'screensize');
if screenSize(3) > screenSize(4)
    % Landscape-format screen:
    sel.h.ax.overview = subplot(4, 6, [3:6; 9:12; 15:18; 21:24]);
    sel.h.ax.eig(1) = subplot(4, 6, 1);
    sel.h.ax.eig(2) = subplot(4, 6, 7);
    sel.h.ax.eig(3) = subplot(4, 6, 13);
    sel.h.ax.eig(4) = subplot(4, 6, 19);
    sel.h.ax.eig(5) = subplot(4, 6, 14);
    sel.h.ax.eig(6) = subplot(4, 6, 20);
    sel.h.ax.cluster = subplot(4, 6, 2);
    sel.h.ax.roi = subplot(4, 6, 8);
    
    % Create sliders:
    refPos =  get(sel.h.ax.overview, 'Position'); %get refImage position
    sel.h.ui.sliderBlack = uicontrol('Style', 'slider', 'Units', 'Normalized',...
        'Position', [refPos(1)+0.075 refPos(2) - 0.05 .3*refPos(3) 0.02],...
        'Min', 0, 'Max', 1, 'Value', 0, 'SliderStep', [0.01 0.1],...
        'Callback',@sel.cbSliderContrast);
    sel.h.ui.sliderWhite = uicontrol('Style', 'slider', 'Units', 'Normalized',...
        'Position', [refPos(1)+0.35 refPos(2) - 0.05 .3*refPos(3) 0.02],...
        'Min', 0, 'Max', 1, 'Value', 1, 'SliderStep', [0.01 0.1],...
        'Callback',@sel.cbSliderContrast);
    
    %create traces figure
    sel.h.fig.trace = figure('Name','Additional Trace Information');
    sel.h.ax.traceClusters = subplot(2,2,1);
    sel.h.ax.traceSub = subplot(2,2,2);
    sel.h.ax.traceDetrend = subplot(2,2,3);
    sel.h.ax.subSlope = subplot(2,2,4);
    
else
    % Portrait-format screen:
    sel.h.ax.overview = subplot(6, 4, 9:24);
    sel.h.ax.eig(1) = subplot(6, 4, 1);
    sel.h.ax.eig(2) = subplot(6, 4, 2);
    sel.h.ax.eig(3) = subplot(6, 4, 3);
    sel.h.ax.eig(4) = subplot(6, 4, 4);
    sel.h.ax.eig(5) = subplot(6, 4, 7);
    sel.h.ax.eig(6) = subplot(6, 4, 8);
    sel.h.ax.cluster = subplot(6, 4, 5);
    sel.h.ax.roi = subplot(6, 4, 6);
    
    %create traces figure
    sel.h.fig.trace = figure('Name','Additional Trace Information');
    sel.h.ax.traceClusters = subplot(5, 2, 1:4);
    sel.h.ax.traceDetrend = subplot(5, 2, [5, 7]);
    sel.h.ax.subSlope = subplot(5, 2, [6, 8]);
    sel.h.ax.traceSub = subplot(5, 2, [9, 10]);
end

% Set callbacks:
set(sel.h.fig.main, 'WindowButtonDownFcn', @sel.cbMouseclick, ...
    'WindowScrollWheelFcn', @sel.cbScrollwheel, ...
    'WindowKeyPressFcn', @sel.cbKeypress, ...
    'CloseRequestFcn', @sel.cbCloseRequestMain);
set(sel.h.fig.trace, 'CloseRequestFcn', @sel.cbCloseRequestMain);

% Set up timers (they can be used to do calculations in the background to
% improve perceived responsiveness of the GUI):
sel.h.timers.calcRoi = timer('name', 'selectRoisGui:calcRoi', ...
    'timerfcn', @(~, ~) sel.calcRoi, 'executionmode', 'singleshot', 'busymode', 'drop', 'StartDelay', 0.2);
sel.h.timers.loadTraces = timer('name', 'selectRoisGui:loadTraces', ...
    'timerfcn', @(~, ~) sel.cbKeypress([], struct('Key', 'f')), 'executionmode', 'singleshot', 'busymode', 'drop', 'StartDelay', 0.2);

%% Draw images and store image handles:
% Reason: If we have image handles, we can save time by directly updating
% the image cdata, rather than redrawing the entire axis:

% Overview image:
sel.h.img.overview = imagesc(sel.disp.img, 'parent', sel.h.ax.overview);
set(sel.h.ax.overview, 'dataaspect', [1 1 1]);
set(sel.h.ax.overview,'XTick', [], 'YTick', [], 'XTickLabel', [], 'YTickLabel', []); %turn off ticks
colormap(sel.h.ax.overview, 'gray'); %set colormap to gray
title(sel.h.ax.overview, 'Overview')

% "Has been viewed" overlay:
hold(sel.h.ax.overview, 'on')
hasBeenViewedColor = repmat(permute([1; 0.3; 0.6], [2 3 1]), sel.disp.movSize(1), sel.disp.movSize(2));
sel.h.img.hasBeenViewed = imshow(hasBeenViewedColor, 'Parent', sel.h.ax.overview);
hold(sel.h.ax.overview, 'off')

% Eigenvector images:
for ii = 1:numel(sel.h.ax.eig)
   sel.h.img.eig(ii) = imshow(zeros(sel.roiInfo.covFile.nh), 'Parent', sel.h.ax.eig(ii));
end

% Cluster image:
sel.h.img.cluster = imshow(zeros(sel.roiInfo.covFile.nh), 'Parent', sel.h.ax.cluster);

% ROI overlay image:
sel.h.img.roi = imshow(zeros(sel.roiInfo.covFile.nh), 'Parent', sel.h.ax.roi);

% Draw everything:
sel.updateOverviewDisplay;

% Maximize figure window:
jFrame = get(sel.h.fig.main, 'JavaFrame');
drawnow % Required for maximization to work.
jFrame.setMaximized(1);