function ref = meanRef(obj,movNums,sliceNum,channelNum,isAvg)
    % Constructs a mean reference image of an acquisition after motion 
    % correction using the derived data structure, without requiring
    % loading movie files
    %
    % ref = meanRef(obj,movNums,sliceNum,channelNum)
    %
    % movNums input can be an arbitrary index vector, or by default
    % includes all movies with derived data
    if isempty(obj.derivedData)
        error('This Acquisition is not associated with derived data')
    end
    if ~exist('movNums','var') || isempty(movNums)
        movNums = 1:length(obj.derivedData);
    end
    if ~exist('sliceNum','var') || isempty(sliceNum)
        sliceNum = 1;
    end
    if ~exist('channelNum','var') || isempty(channelNum)
        channelNum = 1;
    end
    if ~exist('isAvg','var') || isempty(isAvg)
        isAvg = true;
    end
    
    %Initialize zero matrix, sum in loop over movies and normalize by number of movies summed
    [h, w] = size(obj.derivedData(1).meanRef.slice(sliceNum).channel(channelNum).img);
    nMovies = length(movNums);
    
    ref = zeros(h, w, nMovies);
    for ii = 1:numel(movNums)
        if ~isempty(obj.derivedData(movNums(ii)).meanRef)
            ref(:, :, ii) = obj.derivedData(movNums(ii)).meanRef.slice(sliceNum).channel(channelNum).img;
        end
    end
    
    if isAvg
        ref = nanmean(ref, 3);
    end
end