%demo for getting description of classified image
image_path = 'C:/Users/isayk/Desktop/images/firetruck.png';%'C:\Users\isayk\Desktop\images\car.png';%'../../examples/images/cat.jpg'
im = imread(image_path);

%MAIN USAGE CASE
%true, because want to run on GPU
desc = classify_image(im, true);
%%%%%%%%%%%%%%%%

fprintf([desc '\n']);