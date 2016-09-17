trafficVid = VideoReader('Camera_1.avi');


while trafficVid.CurrentTime < trafficVid.Duration
    singleFrame = readFrame(trafficVid);
    imshow(singleFrame)
    [x] = processFrame()
    key = waitforbuttonpres
end
