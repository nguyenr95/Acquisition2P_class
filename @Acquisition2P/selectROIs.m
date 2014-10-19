function selectROIs(obj,img,sliceNum,channelNum,smoothWindow)

%GUI for sorting through seeds / pixel-pixel correlation matrices to select
%appropriate ROIs for an acquisition

%img is the reference image used to select spatial regions, but is not used
%in the actual calculation of ROIs or neuropil (i.e. you can do whatever
%you want to it and it wont screw up cell selection). defaults to the
%square root of the mean image.
%smoothWindow is the length (not std) of gaussian kernel used to smooth traces for
%display and for fitting neuropil subtraction coefficients (standard
%deviation of gaussian window equals smoothWindow / 5)

% Click on reference image to select a seed region for pixel clustering
% Use scroll wheel to adjust # of clusters in current region
% Use 'tab' to cycle currently selected ROI through all clusters, 'f' to
% view (and compare) traces from multiple ROIs, 'space' to select and evaluate cell
% body-neuropil pairings, '1'-'9' to save an ROI or pairing w/ the corresponding
% numbered group, and 'backspace' to delete the last ROI
% See callback functions for more detail

%Currently uses figures 783-786 as auxilliaries for displaying traces

%% Error checking and input handling
if ~exist('img','var') || isempty(img)
    img = sqrt(obj.meanRef);
    img(isnan(img)) = 0;
    img = adapthisteq(img/max(img(:)));
end
if ~exist('sliceNum','var') || isempty(sliceNum)
    sliceNum = 1;
end
if ~exist('channelNum','var') || isempty(channelNum)
    channelNum = 1;
end
if ~exist('smoothWindow','var') || isempty(smoothWindow)
    smoothWindow = 15;
end

if isempty(obj.roiInfo)
    error('no ROI info is associated with this Acquisition')
elseif ~isfield(obj.roiInfo.slice(sliceNum),'covFile')
    error('Pixel-Pixel correlation matrix has not been calculated')
end

if isempty(obj.indexedMovie)
    warning('No indexed movie is associated with this Acquisition. Attempting to load traces will throw an error'),
end

%% Initialize gui data structure
gui = struct;
%Normalize image and add color channels
img = (img-prctile(img(:),1));
img = img/prctile(img(:),99);
gui.movSize = size(img);
gui.img = repmat(img,[1 1 3]);
% Grab roiInfo from object, and initialize new roi labels/list if needed
gui.roiInfo = obj.roiInfo.slice(sliceNum);
if ~isfield(gui.roiInfo,'roiList') || isempty(gui.roiInfo.roiList)
    %If this is acq object has not been processed before, initialize fields
    gui.roiInfo.roiLabels = zeros(size(img));
    obj.roiInfo.slice(sliceNum).roiLabels = [];
    obj.roiInfo.slice(sliceNum).roiList = [];
    obj.roiInfo.slice(sliceNum).grouping = [];
    obj.roiInfo.slice(sliceNum).roi = struct;
end
gui.roiInfo.roiList = unique(gui.roiInfo.roiLabels(:));
% Set the current ROI to be 1 greater than last selected
gui.cROI = max(gui.roiInfo.roiList)+1;
gui.roiInfo.roiList(gui.roiInfo.roiList==0) = [];
gui.roiColors = lines(30);
% Specify slice and channel gui correponds to, and pass handles to the
% appropriate acquisition object and pixel-pixel covariance matrix
gui.sliceNum = sliceNum;
gui.channelNum = channelNum;
gui.smoothWindow = smoothWindow;
gui.covFile = matfile(gui.roiInfo.covFile);
gui.hAcq = obj;

%Create memory mapped binary file of movie
gui.movMap = memmapfile(obj.indexedMovie.slice(sliceNum).channel(channelNum).fileName,'Format','uint16');
%% Create GUI figure
gui.hFig = figure;
%Layout is based on screen size
screenSize = get(0,'screensize');
if screenSize(3) > screenSize(4)
    gui.hAxRef = subplot(4, 6, [3:6; 9:12; 15:18; 21:24]);
    gui.hEig1 = subplot(4,6,1);
    gui.hEig2 = subplot(4,6,7);
    gui.hEig3 = subplot(4,6,13);
    gui.hEig4 = subplot(4,6,19);
    gui.hEig5 = subplot(4,6,14);
    gui.hEig6 = subplot(4,6,20);
    gui.hAxClus = subplot(4, 6, 2);
    gui.hAxROI = subplot(4, 6, 8);    
else
    gui.hAxRef = subplot(6, 4, 9:24);
    gui.hEig1 = subplot(6, 4,1);
    gui.hEig2 = subplot(6, 4,2);
    gui.hEig3 = subplot(6, 4,3);
    gui.hEig4 = subplot(6, 4,4);
    gui.hEig5 = subplot(6, 4,7);
    gui.hEig6 = subplot(6, 4,8);
    gui.hAxClus = subplot(6, 4, 5);
    gui.hAxROI = subplot(6, 4, 6);    
end

%Set callbacks and update display of ROIs on reference
set(gui.hFig, 'WindowButtonDownFcn', @cbMouseclick, ...
              'WindowScrollWheelFcn', @cbScrollwheel, ...
              'KeyPressFcn', @cbKeypress);
gui.hImgMain = imshow(gui.img, 'parent', gui.hAxRef);
title(gui.hAxRef, 'Reference'),
set(gui.hFig, 'userdata', gui),
updateReferenceDisplay(gui.hFig),
    
end

function cbMouseclick(obj, ~)
%Allows selecting a seed location around which to perform clustering
%and select ROIs

gui = get(obj, 'userdata');
displayWidth = gui.covFile.radiusPxCov+1;

%Get current click location
clickCoord = get(gui.hAxRef, 'currentpoint');
if isfield(gui,'hROIpt')
    delete(gui.hROIpt),
end
row = clickCoord(1, 2);
col = clickCoord(1, 1);
seedRow = round(row/gui.covFile.seedBin);
seedCol = round(col/gui.covFile.seedBin);

% Ignore clicks that are outside of the image:
[h, w] = size(gui.img);
if row<1 || col<1 || row>h || col>w
    return
end

%If click is valid, define new ROIpt at click location, get nearest seed 
%point in linear indexing format, and reset cell / cluster status
gui.hROIpt = impoint(gui.hAxRef,clickCoord(1,1:2));
seedNum = (seedCol-1)*round(h/gui.covFile.seedBin) + seedRow;
gui.seedNum = seedNum;
gui.clusterNum = 1;
gui.traceF = [];
gui.indBody = [];
gui.indNeuropil = [];
gui.roiInd = [];

%Get data from cov file and calculate cuts
nNeighbors = gui.covFile.nNeighbors(1,seedNum);
pxNeighbors = gui.covFile.pxNeighbors(1:nNeighbors,seedNum);
covMat = gui.covFile.seedCov(1:nNeighbors,1:nNeighbors,seedNum);
%dFMat = double(covMat./(gui.mRef(pxNeighbors)*gui.mRef(pxNeighbors)'));
gui.pxNeighbors = pxNeighbors;

%Construct matrices for normCut algorithm
W = double(corrcov(covMat));
D = diag(sum(W));
[eVec,eVal] = eigs((D-W),D,7,-1e-10);
[~,eigOrder] = sort(diag(eVal));
gui.cutVecs = eVec(:,eigOrder(2:7));

%Update cut display axes
mask = zeros(512);
for nEig = 1:6
    mask(pxNeighbors) = gui.cutVecs(:,nEig);
    hEig = eval(sprintf('gui.hEig%d',nEig));
    imshow(scaleImg(mask),'Parent',hEig),
    axes(hEig),
    xlim([col-displayWidth col+displayWidth]),
    ylim([row-displayWidth row+displayWidth]),
    title(sprintf('Cut #%1.0f',nEig)),
end

%Display new ROI
set(gui.hFig, 'userdata', gui);
calcROI(gui.hFig);

end

function cbKeypress(obj, evt)
%Allows interactive selection / manipulation of ROIs. Possibly keypresses:
% 'tab' - Cycles through selection of each cluster in seed region as current ROI.
% 'f' - loads fluorescence trace for currently selected ROI, can be iteratively called to display multiple traces within single seed region
% 'space' - selects current ROI as cell body or neuropil, depending on state, and displays evaluative plots
% '1'-'9' - Selects current ROI or pairing and assigns it to grouping 1-9
% 'backspace' - (delete key) Deletes most recently selected ROI or pairing

gui = get(obj, 'userdata');

switch evt.Key
    case 'backspace'
        if gui.cROI <=1
            return
        end
        % Decrement roi Counter and blank gui label/list
        gui.cROI = gui.cROI - 1;
        gui.roiInfo.roiLabels(gui.roiInfo.roiLabels == gui.cROI) = 0;
        gui.roiInfo.roiList(gui.roiInfo.roiList == gui.cROI) = [];
        
        % Remove indexes from roiInfo and update acquisition object
        gui.roiInfo.roi(gui.cROI) = [];
        gui.roiInfo.grouping(gui.cROI) = 0;
        gui.hAcq.roiInfo.slice(gui.sliceNum) = gui.roiInfo;
        
        %Update Display
        gui.roiTitle = title(gui.hAxROI, 'Last ROI deleted');
        set(gui.hFig, 'userdata', gui);
        updateReferenceDisplay(gui.hFig);
        
    case {'1', '2', '3', '4', '5', '6', '7', '8', '9'}
        roiGroup = str2double(evt.Key);
        gui.roiInfo.grouping(gui.cROI) = roiGroup;
        
        %Check to see if a cell body-neuropil pairing is selected
        selectStatus = strcmp('This trace loaded', get(gui.roiTitle,'string'));
        if ~selectStatus || isempty(gui.indBody) || isempty(gui.indNeuropil)
            % Save information for currently selected ROI grouping
            gui.roiInfo.roi(gui.cROI).indBody = find(gui.roiMask);
            newTitle = 'ROI Saved';
        else
            % Save information for recently selected pairing
            gui.roiInfo.roi(gui.cROI).indBody = gui.indBody;
            gui.roiInfo.roi(gui.cROI).indNeuropil = gui.indNeuropil;
            gui.roiInfo.roi(gui.cROI).subCoef = gui.neuropilCoef(2);
            newTitle = 'Cell-Neuropil Pairing Saved';
        end
          
        % Update roilabels, list, display. Increment ROI counter
        gui.roiInfo.roiLabels(gui.roiInfo.roi(gui.cROI).indBody) = gui.cROI;
        gui.roiInfo.roiList = sort([gui.roiInfo.roiList; gui.cROI]);
        gui.cROI = gui.cROI + 1;
        set(gui.hFig, 'userdata', gui);
        updateReferenceDisplay(gui.hFig);
        gui.roiTitle = title(gui.hAxROI, newTitle);
        
        % Save gui data to acquisition object handle
        gui.hAcq.roiInfo.slice(gui.sliceNum) = gui.roiInfo;
    case 'f'
        gui.roiTitle = title(gui.hAxROI, 'Loading Trace for Current ROI');
        drawnow,
        
        %Add new ROI fluorescence trace to end of traceF matrix
        mov = gui.movMap.Data;
        mov = reshape(mov,gui.movSize(1)*gui.movSize(2),[]);
        gui.roiInd = find(gui.roiMask);
        gui.traceF(end+1,:) = mean(mov(gui.roiInd,:));
        
        %Normalize, smooth, and plot all traces
        dF = bsxfun(@rdivide,gui.traceF,median(gui.traceF,2));
        for i=1:size(dF,1)
            dF(i,:) = conv(dF(i,:)-1,gausswin(gui.smoothWindow)/sum(gausswin(gui.smoothWindow)),'same');
        end
        figure(786),
        plot(dF')
        gui.roiTitle = title(gui.hAxROI, 'This trace loaded');
        
        % reset neuroPil index, to prevent accidental saving of previous pairing
        gui.indNeuropil = [];
    case 'space'
        %Determine if selection is new cell body or paired neuropil
        neuropilSelection = strcmp('Select neuropil pairing', get(gui.roiTitle,'string'));
        if ~neuropilSelection
            %Get indices of current ROI as cell body + update title state
            gui.indBody = find(gui.roiMask);
            gui.roiTitle = title(gui.hAxROI, 'Select neuropil pairing');
        elseif neuropilSelection
            gui.roiTitle = title(gui.hAxROI, 'Loading Trace for cell-neuropil pairing');
            drawnow,
            
            %Get indices of current ROI as paired neuropil
            gui.indNeuropil = find(gui.roiMask);
            
            %Load cell body and neuropil fluorescence
            mov = gui.movMap.Data;
            mov = reshape(mov,gui.movSize(1)*gui.movSize(2),[]);
            cellBody = mean(mov(gui.indBody,:));
            cellNeuropil = mean(mov(gui.indNeuropil,:));
            
            %Smooth fluorescence traces
            cellBody = conv(cellBody,gausswin(gui.smoothWindow)/sum(gausswin(gui.smoothWindow)),'valid');
            cellNeuropil = conv(cellNeuropil,gausswin(gui.smoothWindow)/sum(gausswin(gui.smoothWindow)),'valid');
            
            %Extract subtractive coefficient btw cell + neuropil and plot
            %cellInd = cellBody<median(cellBody);
            cellInd = cellBody<median(cellBody)+mad(cellBody)*2; %& cellNeuropil<prctile(cellNeuropil,90);
            %cellInd = ones(length(cellNeuropil),1);
            gui.neuropilCoef = robustfit(cellNeuropil(cellInd)-median(cellNeuropil),cellBody(cellInd)-median(cellBody),...
                'bisquare',4);
            figure(783),plot(cellNeuropil-median(cellNeuropil),cellBody-median(cellBody),'.','markersize',3)
            xRange = round(min(cellNeuropil-median(cellNeuropil))):round(max(cellNeuropil-median(cellNeuropil)));
            hold on, plot(xRange,xRange*gui.neuropilCoef(2) + gui.neuropilCoef(1),'r'),
            hold off,
            title(sprintf('Fitted subtractive coefficient is: %0.3f',gui.neuropilCoef(2))),
            
            %Calculate corrected dF and plot
            dF = cellBody-cellNeuropil*gui.neuropilCoef(2);
            dF = dF/prctile(cellBody,10);
            dF = dF - median(dF);
            figure(784),
            plot(cellNeuropil,'k'),
            hold on,
            plot(cellBody,'r'),
            hold off,
            figure(785),
            plot(dF,'linewidth',1.5)
            gui.roiTitle = title(gui.hAxROI, 'This trace loaded');
            figure(gui.hFig),
        end
    case 'tab'
        %Increase currently selected cluster by 1
        clusters = max(gui.allClusters(:));
        gui.cluster = mod(gui.cluster+1,clusters+1);
        
        %If index exceeds # of clusters, loop back to first cluster
        if gui.cluster == 0
            gui.cluster = 1;
        end
        
        %Update ROI display
        set(gui.hFig, 'userdata', gui);
        displayROI(gui.hFig),
        gui = get(obj, 'userdata');
end

set(gui.hFig, 'userdata', gui);
end

function cbScrollwheel(obj, evt)
%Allows interactive adjustment of the number of clusters / cuts to perform

gui = get(obj, 'userdata');
switch sign(evt.VerticalScrollCount)
    case -1 % Scrolling up
        if gui.clusterNum < 6
            gui.clusterNum = gui.clusterNum + 1;
        else
            return
        end
    case 1 % Scrolling down
        if gui.clusterNum > 1
            gui.clusterNum = gui.clusterNum - 1;
        else
            return
        end
end
%Recalculate clusters with new cluster count
set(gui.hFig, 'userdata', gui);
calcROI(gui.hFig);
end

function updateReferenceDisplay(hFig)
%Helper function that updates the reference image with current ROI labels

gui = get(hFig, 'userdata');
% Add colored ROI labels:
if ~isempty(gui.roiInfo.roiList)
    clut = gui.roiColors(mod(1:max(gui.roiInfo.roiList), 30)+1, :);
    roiCdata = double(myLabel2rgb(gui.roiInfo.roiLabels, clut))/255;
    cdata = scaleImg(gui.img.*roiCdata);
else
    cdata = scaleImg(gui.img);
end
set(gui.hImgMain, 'cdata', cdata);
set(gui.hFig, 'userdata', gui);
end

function calcROI(hFig)
%Helper function that performs clustering using n simultaneous normcuts and
%updates cluster/ROI display accordingly

gui = get(hFig, 'userdata');
clusterNum = gui.clusterNum;
roiCenter = round(getPosition(gui.hROIpt));
pxNeighbors = gui.pxNeighbors;
displayWidth = gui.covFile.radiusPxCov+1;

%Perform kmeans clustering on n smallest cuts
clusterIndex = kmeans(gui.cutVecs(:,1:clusterNum),clusterNum+1,'Replicates',10);

%Display current clustering
mask = zeros(512);
mask(pxNeighbors) = clusterIndex;
gui.allClusters = mask;
imshow(label2rgb(mask),'Parent',gui.hAxClus),
axes(gui.hAxClus),
xlim([roiCenter(1)-displayWidth roiCenter(1)+displayWidth]),
ylim([roiCenter(2)-displayWidth roiCenter(2)+displayWidth]),
title(gui.hAxClus, sprintf('Clustering with %01.0f cuts',clusterNum)),

%Autoselect cluster at click position and display
gui.cluster = gui.allClusters(roiCenter(2),roiCenter(1));
gui.roiTitle = title(gui.hAxROI, 'ROI Selection');
set(gui.hFig, 'userdata', gui);
displayROI(hFig),
end

function displayROI(hFig)
%Helper function which updates display of currently selected ROI in overlay
%panel

gui = get(hFig, 'userdata');
enforceContinuity = 1;
currentTitle = get(gui.roiTitle,'string');
if strcmp(currentTitle,'This trace loaded')
    currentTitle = 'ROI Selection';
elseif strcmp(currentTitle,'Select neuropil pairing')
    enforceContinuity = 0;
end
displayWidth = ceil(gui.covFile.radiusPxCov+2);
roiCenter = round(getPosition(gui.hROIpt));
gui.roiMask = gui.allClusters == gui.cluster;
if enforceContinuity == 1
    CC = bwconncomp(gui.roiMask);
    numPix = cellfun(@numel,CC.PixelIdxList);
    [~,bigROI] = max(numPix);
    gui.roiMask(~ismember(1:512^2,CC.PixelIdxList{bigROI})) = 0;
end
iOffS = (1+displayWidth-roiCenter(2)) * ((roiCenter(2)-displayWidth)<1);
iOffE = (roiCenter(2)+displayWidth-gui.movSize(1)) * ((roiCenter(2)+displayWidth)>gui.movSize(1));
jOffS = (1+displayWidth-roiCenter(1)) * ((roiCenter(1)-displayWidth)<1);
jOffE = (roiCenter(1)+displayWidth-gui.movSize(2)) * ((roiCenter(1)+displayWidth)>gui.movSize(2));
roiImg = gui.img(roiCenter(2)-displayWidth+iOffS:roiCenter(2)+displayWidth-iOffE,...
    roiCenter(1)-displayWidth+jOffS:roiCenter(1)+displayWidth-jOffE,1);
roiImg = repmat(scaleImg(roiImg)/.9 +.1,[1 1 3]);
img = gui.img;
img(roiCenter(2)-displayWidth+iOffS:roiCenter(2)+displayWidth-iOffE,...
    roiCenter(1)-displayWidth+jOffS:roiCenter(1)+displayWidth-jOffE,1:3) = roiImg;
roiOverlay(:,:,1) = gui.roiMask;
roiOverlay(:,:,2) = 1;
roiOverlay(:,:,3) = ~gui.roiMask;
imshow(img .* roiOverlay,'Parent',gui.hAxROI),
axes(gui.hAxROI),
xlim([roiCenter(1)-displayWidth roiCenter(1)+displayWidth]),
ylim([roiCenter(2)-displayWidth roiCenter(2)+displayWidth]),
gui.roiTitle = title(gui.hAxROI, currentTitle);
set(gui.hFig, 'userdata', gui);
end

function RGB = myLabel2rgb(label, cmap)
% Like MATLAB label2RGB, but skipping some checks to be faster:
cmap = [[1 1 1]; cmap]; % Add zero color
RGB = ind2rgb8(double(label)+1, cmap);
end

function img = scaleImg(img)
img = img-min(img(:));
img = img./max(img(:));
end