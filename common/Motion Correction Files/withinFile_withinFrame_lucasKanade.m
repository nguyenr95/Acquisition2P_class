function movStruct = withinFile_withinFrame_lucasKanade(...
    obj, movStruct, scanImageMetadata, movNum, opMode)
% movStruct = withinFile_withinFrame_lucasKanade(obj, movStruct, scanImageMetadata, movNum, opMode)
% finds/corrects in-frame motion with an algorithm that takes into account
% that images are acquired by raster scanning (Greenberg and Kerr, 2009)

nSlice = numel(movStruct.slice);
nChannel = numel(movStruct.slice(1).channel);

isGpu = false;

if isGpu
    gpu = gpuDevice;
    pctRunOnAll reset(gpuDevice);
    wait(gpu)
    memAvailable = gpu.AvailableMemory;
end
isEqualizeLuminace = false;

switch opMode
    case 'identify'
        refCh = obj.motionRefChannel;
        refMov = obj.motionRefMovNum;
        for iSl = 1:nSlice
            [h, w, z] = size(double(movStruct.slice(iSl).channel(refCh).mov));
            
            % It is important to exclude the black bars that are
            % present in older Scanimage files because they don't
            % translate and will bias the results. We simply cut off
            % 10 % on either side:
            isEdge = (1:w) < 0.1*w | (1:w) > 0.9*w;
            movTemp = movStruct.slice(iSl).channel(refCh).mov(:, ~isEdge, :);
            
            % Perform luminance equalization (this may be helpful for
            % movies with very uneven brightness, e.g. one highly
            % overexpressing region besides a healthy region of interest):
            if isEqualizeLuminace
                localLuminance = imgaussfilt(movTemp, round(h/12));
                movTemp = ...
                    bsxfun(@rdivide, movTemp, localLuminance);
				movTemp(~isfinite(movTemp)) = 0;
            end
            
            % Perform whole-frame translation correction (this is fast and
            % improves the quality of the reference used for the Lucas
            % Kanade step):
            % Use the old wholeframe code rather than the recursive
            % function that builds up a mean image, because the recursive
            % function can fail catastrophically if individual frames are
            % very low SNR:
            [xTrans, yTrans] = track_subpixel_wholeframe_motion_fft_forloop(...
                movTemp, mean(movTemp, 3));
            movTemp = translateAcq(movTemp, xTrans, yTrans, 0);
            
            % Calculate reference on full-frame-corrected movie:
            ref = mean(movTemp, 3);
            ref = single(ref);
            
            % Find within-frame displacements:
            [movTemp, dpx, dpy, basisFunctions] = ...
                doLucasKanadeSPMD(single(movTemp), ref);
            
            % Combine full-frame and within-frame displacements:
            dpx = bsxfun(@minus, dpx, xTrans);
            dpy = bsxfun(@minus, dpy, yTrans);
                        
            % Find global displacement with respect to global reference
            % image:
            if movNum == refMov
                % Apply shifts to get reference image (we can't just use
                % movTemp because we cut off its edges earlier):
                tformGlobal = affine2d;
                obj.shifts(movNum).slice(iSl).x = createDispFieldFunctionX(h, w, z, basisFunctions, dpx, dpy, tformGlobal);
                obj.shifts(movNum).slice(iSl).y = createDispFieldFunctionY(h, w, z, basisFunctions, dpx, dpy, tformGlobal);
                
                Dx = obj.shifts(movNum).slice(iSl).x();
                Dy = obj.shifts(movNum).slice(iSl).y();
                
                for iCh = 1:nChannel
                    for f = 1:z
                        movStruct.slice(iSl).channel(iCh).mov(:,:,f) = ...
                            interp2(...
                                movStruct.slice(iSl).channel(iCh).mov(:,:,f), ...
                                Dx(:,:,f), ...
                                Dy(:,:,f), ...
                                'linear', nan);
                    end
                    obj.derivedData(movNum).meanRef.slice(iSl).channel(iCh).img = ...
                        nanmean(movStruct.slice(iSl).channel(iCh).mov, 3);
                end
              
                obj.motionRefImage.slice(iSl).img = ...
                    nanmean(movStruct.slice(iSl).channel(refCh).mov, 3);
                
            else                
                refGlobal = obj.motionRefImage.slice(iSl).img(:, ~isEdge);
				if isEqualizeLuminace
					localLuminance = imgaussfilt(refGlobal, round(h/12));
					refGlobal = refGlobal./localLuminance;
					refGlobal(~isfinite(refGlobal)) = 0;
				end
				
                refHere = nanmedian(movTemp, 3); % movTemp already had its edges cut off above.
                
                % First, we find translation only. The subsequent affine
                % step only works robustly if the translation has already
                % been removed:
                [xTrans, yTrans] = track_subpixel_wholeframe_motion_fft_forloop(...
                    refHere, refGlobal);
                Tinit = affine2d;
                Tinit.T = [1 0 0; 0 1 0; xTrans yTrans 1];
                
                % Find affine transformation using mutual information
                % metric:
                opt = imregconfig('Monomodal');
                opt.MaximumIterations = 300;
                opt.RelaxationFactor = 0.9;
                met = registration.metric.MattesMutualInformation;
                RA = imref2d([h, sum(~isEdge)]);      
                tformGlobal = imregtform(refHere, RA, refGlobal, RA, ...
                    'affine', opt, met, ...
                    'InitialTransformation', Tinit, 'PyramidLevels', 1);
            end
            
            % The motion correction algorithm calculates a rigid shift for
            % each line (because lines are scanned fast, so there is
            % probably no shift within a line). The displacement field for
            % the entire frame is created by expanding the line shifts
            % across the entire frame (as if multiplying them with a
            % meshgrid). However, saving them in full matrices would
            % require as much space as the movie itself. Therefore, we
            % simply save them as anonymous functions that calculate the
            % full matrix on demand. This works because anonymous function
            % handles contain all the data that is present in the workspace
            % in which they were created. The functions are evaluated by
            % using empty parentheses, like this: fullMatrix = Dx(). Such
            % empty parentheses are also allowed after normal numeric
            % matrices. So to write a function that can deal with both
            % matrix and functional inputs, we can simply add () after the
            % relevant variables.
            
            % These functions take the height-by-1 lineShift arrays and
            % expand them along the width and nFrames-dimensions. At the
            % same time, they add values corresponding to the
            % grid-positions of each pixel (same as if we created grid
            % matrixes with MESHGRID, but more efficient).
            obj.shifts(movNum).slice(iSl).x = createDispFieldFunctionX(h, w, z, basisFunctions, dpx, dpy, tformGlobal);
            obj.shifts(movNum).slice(iSl).y = createDispFieldFunctionY(h, w, z, basisFunctions, dpx, dpy, tformGlobal);
        end
        
    case 'apply'
        for iSl = 1:nSlice
            z = size(movStruct.slice(iSl).channel(1).mov, 3);
            % Get full displacement fields:
            Dx = obj.shifts(movNum).slice(iSl).x();
            Dy = obj.shifts(movNum).slice(iSl).y();

            for iCh = 1:nChannel
                % This for-loop is faster than using interpn without a
                % loop, both on the CPU and the GPU. Re-evaluate this if we
                % have a GPU that can fit an entire movie into RAM.
                for f = 1:z
                    movStruct.slice(iSl).channel(iCh).mov(:,:,f) = ...
                        interp2(...
                            movStruct.slice(iSl).channel(iCh).mov(:,:,f), ...
                            Dx(:,:,f), ...
                            Dy(:,:,f), ...
                            'linear', nan);
                end
                obj.derivedData(movNum).meanRef.slice(iSl).channel(iCh).img = ...
                    nanmean(movStruct.slice(iSl).channel(iCh).mov, 3);
            end
        end
    end
end

% The following two functions create and return the function handles that
% calculate displacement fields on-demand. The handles are created in
% separate functions, rather than in the main function, because the handles
% will contain copies of the entire workspace of their parent function,
% even including variables that are not used by the anonymous function. By
% putting them into separate functions, we can isolate them from all the
% larger movie-related variables that are in the workspace of the main
% function:
function fn = createDispFieldFunctionX(h, w, z, basisFunctions, dpx, dpy, tformGlobal)
fn = @dispFieldX;
    function dx = dispFieldX
        % Get local displacement field:
        lineShiftX = zeros(h, z);
        lineShiftY = zeros(h, z);
        for f = 1:z
            lineShiftX(:, f) = basisFunctions*dpx(:, f);
            lineShiftY(:, f) = basisFunctions*dpy(:, f);
        end
        dx = bsxfun(@plus, 1:w, permute(lineShiftX, [1, 3, 2]));
        dy = bsxfun(@plus, zeros(1, w), permute(bsxfun(@plus, (1:h)', lineShiftY), [1, 3, 2]));
        
        % Add global transformation:
        [dx, ~] = transformPointsInverse(tformGlobal, dx, dy);
    end
end

function fn = createDispFieldFunctionY(h, w, z, basisFunctions, dpx, dpy, tformGlobal)
fn = @dispFieldY;
    function dy = dispFieldY
        % Get local displacement field:
        lineShiftX = zeros(h, z);
        lineShiftY = zeros(h, z);
        for f = 1:z
            lineShiftX(:, f) = basisFunctions*dpx(:, f);
            lineShiftY(:, f) = basisFunctions*dpy(:, f);
        end
        dx = bsxfun(@plus, 1:w, permute(lineShiftX, [1, 3, 2]));
        dy = bsxfun(@plus, zeros(1, w), permute(bsxfun(@plus, (1:h)', lineShiftY), [1, 3, 2]));
        
        % Add global transformation:
        [~, dy] = transformPointsInverse(tformGlobal, dx, dy);
    end
end