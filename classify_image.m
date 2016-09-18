function [desc] = classify_image(image, use_gpu)

[vec, id] = classification_demo(image,use_gpu);

%now look up id in synset descritptions to obtain word description
%fprintf(['Classified: ' num2str(id) '\n']);

%load dictionary
dict = importdata('C:\Users\isayk\Desktop\git\caffe-windows\data\ilsvrc12\synset_words.txt');
%fprintf([dict{id} '\n']);
%fprintf([dict{id}(11:end) '\n']);

%get descriptors
descriptors = dict{id}(11:end); %cutting off n01440764
toks = strsplit(descriptors, ', ');

%return the first descriptor
desc = toks{1};
%fprintf([toks{1} '\n']);