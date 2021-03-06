function multiObjectTracking(inputVid)
% Create System objects used for reading video, detecting moving objects,
% and displaying the results.
obj = setupSystemObjects();
vidTitle = inputVid;

tracks = initializeTracks(); % Create an empty array of tracks.

nextId = 1; % ID of the next track
classLabels = cell(0,1);
hfig = imgcf;
set(hfig, 'MenuBar', 'none');
set(hfig, 'ToolBar', 'none');
set(hfig, 'Name', 'Tracked Objects');

scrsz = get(groot,'ScreenSize');
pollutionfig = figure('Position', [20 scrsz(4)/8 700 scrsz(4)/4]);
set(pollutionfig, 'MenuBar', 'none');
set(pollutionfig, 'ToolBar', 'none');
set(pollutionfig, 'Name', 'CO2 Analysis For Region Filmed By Camera');

passengercar_pol = 0;
schoolbus_pol = 0;

currnumcars = 0;
currnumbuses = 0;

secondcount = 1;

% Detect moving objects, and track them across video frames.
while ~isDone(obj.reader)
    frame = readFrame();
    [centroids, bboxes, mask] = detectObjects(frame);
    predictNewLocationsOfTracks();
    [assignments, unassignedTracks, unassignedDetections] = ...
        detectionToTrackAssignment();

    updateAssignedTracks();
    updateUnassignedTracks();
    deleteLostTracks();
    createNewTracks();

    displayTrackingResults();
end

function obj = setupSystemObjects()
        % Initialize Video I/O
        % Create objects for reading a video from a file, drawing the tracked
        % objects in each frame, and playing the video.

        % Create a video file reader.
        obj.reader = vision.VideoFileReader(inputVid);

        % Create two video players, one to display the video,
        % and one to display the foreground mask.
        obj.videoPlayer = vision.VideoPlayer('Position', [20, 400, 700, 400], 'Name', 'Camera View');
        obj.maskPlayer = vision.VideoPlayer('Position', [740, 400, 700, 400], 'Name', 'Segmentation Mask');

        % Create System objects for foreground detection and blob analysis

        % The foreground detector is used to segment moving objects from
        % the background. It outputs a binary mask, where the pixel value
        % of 1 corresponds to the foreground and the value of 0 corresponds
        % to the background.

        obj.detector = vision.ForegroundDetector('NumGaussians', 3, ...
            'NumTrainingFrames', 40, 'MinimumBackgroundRatio', 0.7);

        % Connected groups of foreground pixels are likely to correspond to moving
        % objects.  The blob analysis System object is used to find such groups
        % (called 'blobs' or 'connected components'), and compute their
        % characteristics, such as area, centroid, and the bounding box.

        obj.blobAnalyser = vision.BlobAnalysis('BoundingBoxOutputPort', true, ...
            'AreaOutputPort', true, 'CentroidOutputPort', true, ...
            'MinimumBlobArea', 400);
end

function tracks = initializeTracks()
    % create an empty array of tracks
    tracks = struct(...
        'id', {}, ...
        'bbox', {}, ...
        'kalmanFilter', {}, ...
        'age', {}, ...
        'totalVisibleCount', {}, ...
        'consecutiveInvisibleCount', {});
end

 function frame = readFrame()
        frame = obj.reader.step();
 end

function [centroids, bboxes, mask] = detectObjects(frame)

    % Detect foreground.
    mask = obj.detector.step(frame);

    % Apply morphological operations to remove noise and fill in holes.
    mask = imopen(mask, strel('rectangle', [3,3]));
    mask = imclose(mask, strel('rectangle', [15, 15]));
    mask = imfill(mask, 'holes');

    % Perform blob analysis to find connected components.
    [~, centroids, bboxes] = obj.blobAnalyser.step(mask);
end

function predictNewLocationsOfTracks()
    for i = 1:length(tracks)
        bbox = tracks(i).bbox;

        % Predict the current location of the track.
        predictedCentroid = predict(tracks(i).kalmanFilter);

        % Shift the bounding box so that its center is at
        % the predicted location.
        predictedCentroid = int32(predictedCentroid) - bbox(3:4) / 2;
        tracks(i).bbox = [predictedCentroid, bbox(3:4)];
    end
end

function [assignments, unassignedTracks, unassignedDetections] = ...
        detectionToTrackAssignment()

    nTracks = length(tracks);
    nDetections = size(centroids, 1);

    % Compute the cost of assigning each detection to each track.
    cost = zeros(nTracks, nDetections);
    for i = 1:nTracks
        cost(i, :) = distance(tracks(i).kalmanFilter, centroids);
    end

    % Solve the assignment problem.
    costOfNonAssignment = 20;
    [assignments, unassignedTracks, unassignedDetections] = ...
        assignDetectionsToTracks(cost, costOfNonAssignment);
end

function updateAssignedTracks()
    numAssignedTracks = size(assignments, 1);
    for i = 1:numAssignedTracks
        trackIdx = assignments(i, 1);
        detectionIdx = assignments(i, 2);
        centroid = centroids(detectionIdx, :);
        bbox = bboxes(detectionIdx, :);

        % Correct the estimate of the object's location
        % using the new detection.
        correct(tracks(trackIdx).kalmanFilter, centroid);

        % Replace predicted bounding box with detected
        % bounding box.
        tracks(trackIdx).bbox = bbox;

        % Update track's age.
        tracks(trackIdx).age = tracks(trackIdx).age + 1;

        % Update visibility.
        tracks(trackIdx).totalVisibleCount = ...
            tracks(trackIdx).totalVisibleCount + 1;
        tracks(trackIdx).consecutiveInvisibleCount = 0;
    end
end

function updateUnassignedTracks()
    for i = 1:length(unassignedTracks)
        ind = unassignedTracks(i);
        tracks(ind).age = tracks(ind).age + 1;
        tracks(ind).consecutiveInvisibleCount = ...
            tracks(ind).consecutiveInvisibleCount + 1;
    end
end

function deleteLostTracks()
    if isempty(tracks)
        return;
    end

    invisibleForTooLong = 20;
    ageThreshold = 8;

    % Compute the fraction of the track's age for which it was visible.
    ages = [tracks(:).age];
    totalVisibleCounts = [tracks(:).totalVisibleCount];
    visibility = totalVisibleCounts ./ ages;

    % Find the indices of 'lost' tracks.
    lostInds = (ages < ageThreshold & visibility < 0.6) | ...
        [tracks(:).consecutiveInvisibleCount] >= invisibleForTooLong;

    % Delete lost tracks.
    tracks = tracks(~lostInds);
end

function createNewTracks()
    centroids = centroids(unassignedDetections, :);
    bboxes = bboxes(unassignedDetections, :);

    for i = 1:size(centroids, 1)

        centroid = centroids(i,:);
        bbox = bboxes(i, :);

        % Create a Kalman filter object.
        kalmanFilter = configureKalmanFilter('ConstantVelocity', ...
            centroid, [200, 50], [100, 25], 100);

        % Create a new track.
        newTrack = struct(...
            'id', nextId, ...
            'bbox', bbox, ...
            'kalmanFilter', kalmanFilter, ...
            'age', 1, ...
            'totalVisibleCount', 1, ...
            'consecutiveInvisibleCount', 0);

        % Add it to the array of tracks.
        tracks(end + 1) = newTrack;

        % Increment the next id.
        nextId = nextId + 1;
    end
end

function displayTrackingResults()
    % Convert the frame and the mask to uint8 RGB.
    frame = im2uint8(frame);
    mask = uint8(repmat(mask, [1, 1, 3])) .* 255;

    minVisibleCount = 8;
    
    if ~isempty(tracks)

        % Noisy detections tend to result in short-lived tracks.
        % Only display tracks that have been visible for more than
        % a minimum number of frames.
        reliableTrackInds = ...
            [tracks(:).totalVisibleCount] > minVisibleCount;
        reliableTracks = tracks(reliableTrackInds);
        predictedTrackInds = ...
                [reliableTracks(:).consecutiveInvisibleCount] > 0;
        isPredicted = cell(size(reliableTracks));
        isPredicted(predictedTrackInds) = {' predicted'};
        % Display the objects. If an object has not been detected
        % in this frame, display its predicted bounding box.
        if ~isempty(reliableTracks)
            % Get bounding boxes.
            bboxes = cat(1, reliableTracks.bbox);
            
            % Get ids.
            ids = int32([reliableTracks(:).id]);
            for j = 1:size(bboxes, 1)
                if (isequal(isPredicted(j), {' predicted'}))
                    continue
                end
                set(0,'CurrentFigure', hfig);
                subplot(1,size(bboxes, 1),j);
                curChip = imcrop(frame, bboxes(j,1:4));
                
                image(curChip); axis off;

                if (ids(j) > size(classLabels, 1) || isequal(classLabels(ids(j),:), {}))
                    classLabels(ids(j),:)={classify_image(curChip, true)};
                end
            end
            % Create labels for objects indicating the ones for
            % which we display the predicted rather than the actual
            % location.
            labels = classLabels(ids');
            
%             labels = strcat(labels, isPredicted);

            % Draw the objects on the frame.
            for j=1:size(labels, 1)
                if (isequal(isPredicted(j), {' predicted'}))
                    continue
                end
                frame = insertObjectAnnotation(frame, 'rectangle', ...
                bboxes(j,:), labels(j));
            end

            % Draw the objects on the mask.
            for j=1:size(labels, 1)
                if (isequal(isPredicted(j), {' predicted'}))
                    continue
                end
                mask = insertObjectAnnotation(mask, 'rectangle', ...
                bboxes(j,:), labels(j));
            end
            
            %loop through id's and update pollution
            size(ids,2)
            currnumcars = 0;
            currnumbuses = 0;
            
            secondcount = secondcount + 1;
            for j=1:size(ids,2)
                %classLabels(ids(j))
                if (strcmp(classLabels(ids(j)), 'passenger car') || strcmp(classLabels(ids(j)), 'streetcar'))
                    passengercar_pol = passengercar_pol + 0.011; %per frame rate of pollution
                    currnumcars = currnumcars + 1;
                elseif (strcmp(classLabels(ids(j)), 'school bus'))
                    schoolbus_pol = schoolbus_pol + 0.055; %per frame rate of pol
                    currnumbuses = currnumbuses + 1;
                end
            end
        end
    end

    % Display the mask and the frame.
    obj.maskPlayer.step(mask);
    obj.videoPlayer.step(frame);
    
    str= '';
    if size(classLabels,1) > 0 
        str = classLabels(size(classLabels,1));
    end
    
    set(0,'CurrentFigure',pollutionfig);
    clf(pollutionfig);
    carpolstr = ['Cars currently tracked: ' num2str(currnumcars) ' | Car pollution: ' num2str(passengercar_pol/secondcount) ' lb CO2 / sec'];
    buspolstr = ['Buses currently tracked: ' num2str(currnumbuses) ' | Bus pollution: ' num2str(schoolbus_pol/secondcount) ' lb CO2 / sec'];
    totalpolstr = ['Total pollution: ' num2str(passengercar_pol + schoolbus_pol) ' lb CO2'];
    annotation('textbox',[0.1 0.9 0.5 0],'String',carpolstr,'FitBoxToText','on');
    annotation('textbox',[0.1 0.7 0.5 0],'String',buspolstr,'FitBoxToText','on');
    annotation('textbox',[0.1 0.5 0.5 0],'String',totalpolstr,'FitBoxToText','on');
    
    summarystr = 'No summary';
    color = 'black';
    if ((passengercar_pol + schoolbus_pol)/secondcount > 0.09)
        summarystr = 'Summary: The region is experiencing very high levels of pollution.';
        color = [0.6 0 0];
    elseif ((passengercar_pol + schoolbus_pol)/secondcount > 0.05)
        summarystr = 'Summary: The region is experiencing high levels of pollution.';
        color = [0.6 0 0];
    elseif ((passengercar_pol + schoolbus_pol)/secondcount > 0.02)
        summarystr = 'Summary: The filmed region is experiencing mild levels of pollution.';
        color = [0.6 0.6 0];
    elseif ((passengercar_pol + schoolbus_pol)/secondcount > 0.01)
        summarystr = 'Summary: The filmed region is experiencing very little pollution currently.';
        color = [0 0.6 0];
    end
    
    annotation('textbox',[0.1 0.3 0.5 0],'String',summarystr,'FitBoxToText','on','Color', color);
end

end