function exit_code = sid_main(config_in)
%% SID main function. 
% See github wiki for documentation. See sid_config_manage.m for summary of parameters and defaults.
% config_in has to be struct with fields according to sid_config_manage.m, 
% in the future it will also be possible to use varargin arguments instead, as well as correct parsing of system command line arguments

%% Verify input config and set defaults
[valid_config, Input] = sid_config_manage(config_in);
if ~valid_config
    exit_code = -1;
    return;
end

%% Create output folder
mkdir(Input.outdir);

%% Cache and open PSF
if ~strcmp(Input.psf_cache_dir, '')
    [~, rand_string] = fileparts(tempname());
    Input.psf_cache_dir_unique = fullfile(Input.psf_cache_dir, ['sid_nnmf_recon_psf_' rand_string]);
    disp(['Creating tmp dir for psf caching: ' Input.psf_cache_dir_unique]);
    mkdir(Input.psf_cache_dir_unique);
    disp('Copying psf file to tmp dir for caching...');
    copyfile(Input.psffile, Input.psf_cache_dir_unique);
    [~, psf_fname, psf_ext] = fileparts(Input.psffile);
    Input.psffile_in = Input.psffile;
    Input.psffile = fullfile(Input.psf_cache_dir_unique, [psf_fname psf_ext]);
    clear psf_fname;
end
psf_ballistic = matfile(Input.psffile);

if ~isfield(Input.segmentation, 'bottom_cutoff') || isempty(Input.segmentation.bottom_cutoff)
    Input.segmentation.bottom_cutoff = size(psf_ballistic.H,5);
end

%% Prepare cluster object
pctconfig('portrange', [27400 27500] + randi(100)*100);
cluster = parcluster('local');
if ~isfield(Input, 'job_storage_location')
    Input.job_storage_location = tempdir();
end
[~, rand_string] = fileparts(tempname());
Input.job_storage_location_unique = fullfile(Input.job_storage_location, ['nnmf_sid_' rand_string]);
if ~exist(Input.job_storage_location_unique, 'dir')
    mkdir(Input.job_storage_location_unique);
end
cluster.JobStorageLocation = Input.job_storage_location_unique;
disp(cluster);
delete(gcp('nocreate'));

%% Load mask image
if isfield(Input, 'mask_file') && ~isempty(Input.mask_file)
    Input.mask = logical(imread(Input.mask_file));
    figure; imagesc(double(Input.mask), [0 1]); axis image; title('Mask image'); colorbar;
    print(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_mask.pdf']), '-dpdf', '-r300');
else
    Input.mask = true;
end

%% load sensor movie
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Loading LFM movie']);
if ~isempty(Input.gpu_ids')
    gpu_device = gpuDevice(Input.gpu_ids(1));
end
tic;
[sensor_movie, SID_output.movie_size] = read_sensor_movie(Input.indir, Input.x_offset, Input.y_offset, Input.dx, psf_ballistic.Nnum, Input.rectify, Input.frames, Input.mask, Input.crop_border_microlenses, gpu_device);
toc

%% Fit trend
tic
if Input.detrend
    disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Detrending LFM movie']);
    SID_output.baseline_raw = squeeze(mean(sensor_movie,1))';
    if Input.delta <= 0
        smooth_window_span = numel(SID_output.baseline_raw) / max(1, abs(Input.delta));
    else
        smooth_window_span = 2 * Input.delta / Input.frames.step;
    end
    SID_output.baseline = smooth(SID_output.baseline_raw, smooth_window_span, 'sgolay', 3);
    figure; hold on; plot(SID_output.baseline_raw); plot(SID_output.baseline); title('Frame means (post bg subtract), raw + trend fit'); hold off;
    print(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_trend_fit.pdf']), '-dpdf', '-r300');
end

%% De-trend and normalize
if Input.detrend
    sensor_movie = sensor_movie./SID_output.baseline';
    %TODO: check if trend fit worked, i.e. residuals are mostly gaussian
end
sensor_movie_max = max(sensor_movie(:));
sensor_movie = sensor_movie/sensor_movie_max;
toc

%% Compute background and std-image
if Input.bg_sub
    [SID_output.bg_spatial,SID_output.bg_temporal]=rank_1_factorization(sensor_movie,Input.bg_iter);
else
    SID_output.bg_spatial = zeros(size(sensor_movie,1),1);
    SID_output.bg_temporal = zeros(1,size(sensor_movie,2));
end

SID_output.std_image=compute_std_image(sensor_movie,SID_output.bg_spatial,SID_output.bg_temporal);

SID_output.bg_spatial = reshape(SID_output.bg_spatial,SID_output.movie_size(1:2));
SID_output.std_image = reshape(SID_output.std_image,SID_output.movie_size(1:2));

figure; imagesc(SID_output.bg_spatial); axis image; colorbar; title('Spatial background');
print(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_bg_spatial.png']), '-dpng', '-r300');
figure; plot(SID_output.bg_temporal); title('Temporal background');
print(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_bg_temporal.png']), '-dpng', '-r300');

figure; imagesc(SID_output.std_image, [prctile(SID_output.std_image(:), 0) prctile(SID_output.std_image(:), 100.0)]); title('Stddev image'); axis image; axis ij; colorbar;
print(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_stddev_img.png']), '-dpng', '-r600');


%% Find cropping mask, leaving out areas with stddev as in background-only area
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Finding crop space']);
if ~isfield(Input,'crop_params') || isempty(Input.crop_params)
    disp('Find appropriate crop_params!')
    Input.crop_params = [0.2 0.6];
    flag1 = false;
    flag2 = false;
    flag = false;
else
    flag1 = true;
    flag2 = true;
    flag = true;
end

while max(~flag1,max(~flag2,flag))

    if Input.bg_sub
        img = SID_output.bg_spatial;
    else
        img = SID_output.std_image;
    end
    bg = img/max(img(:));
    Nnum = psf_ballistic.Nnum;
    SID_output.microlenses=img;
    for ix=1:size(SID_output.std_image,1)/Nnum
        for iy=1:size(SID_output.std_image,2)/Nnum
            SID_output.microlenses((ix-1)*Nnum+1:ix*Nnum, (iy-1)*Nnum+1:iy*Nnum) = ...
                SID_output.microlenses((ix-1)*Nnum+1:ix*Nnum, (iy-1)*Nnum+1:iy*Nnum) / norm(reshape(SID_output.microlenses((ix-1)*Nnum+1:ix*Nnum,(iy-1)*Nnum+1:iy*Nnum),1,[]));
        end
    end
    Inside = bg;
    h = fspecial('average', 3*psf_ballistic.Nnum);
    Inside=conv2(Inside,h,'same');
    Inside=max(Inside-quantile(Inside(:),Input.crop_params(1)),0);
    Inside=conv2(single(Inside>0),h,'same');
    SID_output.microlenses=Inside.*SID_output.microlenses;
    SID_output.microlenses=max(SID_output.microlenses-quantile(SID_output.microlenses(:),Input.crop_params(2)),0);
    if ~flag1
        figure(); imagesc(Inside); axis image; colorbar; title('Active pixels');
        drawnow expose
        flag1 = input('Does the figure entitled "Active pixels" give a good representation of the activity in the standard-deviation image (previous figure)? (yes=1,no=0)');
        if ~flag1
            disp(['The current value of Input.crop_params(1) is: ' num2str(Input.crop_params(1))]);
            Input.crop_params(1) = input('Enter new Value for Input.crop_params(1): ');
        end
    end
    if ~flag2
        figure(); imagesc(SID_output.microlenses); axis image; colorbar; title('Microlenses');
        drawnow expose
        flag2 = input('Does the figure entitled "Microlenses" give a good representation of the microlens pattern? (yes=1,no=0)');
        if ~flag2
            disp(['The current value of Input.crop_params(2) is: ' num2str(Input.crop_params(2))]);
            Input.crop_params(2) = input('Enter new Value for Input.crop_params(2): ');
        end
    end
    flag = false;
end

if Input.do_crop
    if ~isfield(Input,'crop_mask') || all(Input.crop_mask(:)) == true
        Input.crop_mask=Inside;
        SID_output.crop_mask=Inside;
    end
    [sensor_movie, SID_output] = crop(sensor_movie, SID_output,Inside,Input.crop_mask,Nnum);
else
    Inside = SID_output.std_image * 0 + 1;
    SID_output.idx=find(Inside>0);
end

timestr = datestr(now, 'YYmmddTHHMM');
figure;
hold on;
imagesc(Inside);
contour(Inside, [1e-10 1e-10], 'w');
axis ij;
colorbar();
axis image;
title('Crop mask');
hold off;
print(fullfile(Input.outdir, [timestr '_crop_mask.png']), '-dpng', '-r300');


%% NNMF
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': Generating rank-' num2str(Input.nnmf_opts.rank) '-factorization']);
movie_clip_quantile = 0.8;
opts = Input.nnmf_opts;
if opts.xval_enable  % assemble sub-struct needed for cross-validation in xval.m
    opts.xval.num_part = opts.xval_numpart;
    opts.xval.xval_param = opts.xval_xval_param;
    opts.xval.std_image = SID_output.std_image;
elseif isfield(opts, 'xval')
    opts = rmfield(opts, 'xval');
end
opts.active = SID_output.microlenses > 0;
opts.use_std = Input.use_std;
opts.diagnostic = true; opts.display = true;
low_clip_val = quantile(reshape(gather(sensor_movie(SID_output.microlenses==0, 1:10:end)),1,[]), movie_clip_quantile);

[SID_output.S, SID_output.T] = fast_NMF(...
    max(sensor_movie - low_clip_val, 0), ...
    opts);
SID_output.S = SID_output.S(:, ~isoutlier(sum(SID_output.S,1), 'ThresholdFactor', 10));

if ~Input.optimize_kernel && ~isfield(Input.recon_opts,'ker_shape')
    SID_output.S = [SID_output.S SID_output.std_image(:)]';
else
    SID_output.S = SID_output.S';
end

%% Plot NNMF results
close all;
timestr = datestr(now, 'YYmmddTHHMM');
for i=1:size(SID_output.S, 1)
    figure( 'Position', [100 100 800 800]);%,'visible',false);
    subplot(4,1,[1,2,3]);
    imagesc(reshape(SID_output.S(i,:), size(SID_output.std_image)));
    axis image; colormap('parula'); colorbar;
    title(['NMF component ' num2str(i)]);
    subplot(4,1,4);
    plot(SID_output.T(i,:));
    print(fullfile(Input.outdir, [timestr '_nnmf_component_' num2str(i, '%03d') '.png']), '-dpng', '-r600');
end
%close all;

%% Save checkpoint
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': Saving pre-nmf-recon checkpoint']);
save(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_checkpoint_pre-nmf-recon.mat']), 'Input', 'SID_output');

%% reconstruct spatial filters
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Reconstructing spatial filters']);
opts = Input.recon_opts;
opts.gpu_ids = Input.gpu_ids;
opts.microlenses = SID_output.microlenses;
SID_output.S = reshape(SID_output.S, [size(SID_output.S,1) SID_output.movie_size(1:2)]);

if Input.optimize_kernel
    if isfield(opts,'ker_param')
        opts=rmfield(opts,'ker_param');
    end
    kernel=0;
    while max(kernel(:))==0
        test_recon = reconstruct_S(...
            SID_output.S(ceil(rand(1) * size(SID_output.S,1)), :,:), ...
            psf_ballistic, opts);
        [kernel, SID_output.neur_rad] = find_kernel(...
            test_recon{1}, [1 1 4],...
            Input.neur_rad, Input.native_focal_plane, ...
            Input.axial, Input.gpu_ids(1));
    end
    opts.ker_shape = 'user';
    opts.ker_param = kernel;
else
    % no kernel optimization
    SID_output.neur_rad = Input.neur_rad;
end

SID_output.recon = reconstruct_S(SID_output.S, psf_ballistic, opts);
SID_output.recon_opts = opts;

clear opts

%% Crop reconstructed image with eroded mask, to reduce border artefacts
if numel(Input.mask) > 1 && any(Input.mask ~= 0)
    mask_dilated = imerode(Input.mask, strel('disk', 25));
    mask_dilated =  logical(ImageRect(double(mask_dilated), Input.x_offset, Input.y_offset, Input.dx, psf_ballistic.Nnum, ...
        true, Input.crop_border_microlenses(3), Input.crop_border_microlenses(4), Input.crop_border_microlenses(1), Input.crop_border_microlenses(2)));
    for i = 1:length(SID_output.recon)
        SID_output.recon{i} = SID_output.recon{i} .* mask_dilated;
    end
end

%% Plot reconstructed spatial filters
timestr = datestr(now, 'YYmmddTHHMM');
for i = 1:size(SID_output.S, 1)
    figure('Position', [50 50 1200 600]);
    subplot(1, 4, 1:3);
    hold on;
    imagesc(squeeze(max(SID_output.recon{i}, [], 3)));
    axis image;
    axis ij;
    colorbar;
    hold off;
    subplot(1,4,4)
    imagesc(squeeze(max(SID_output.recon{i}, [], 2)));
    axis ij;
    colorbar;
    print(fullfile(Input.outdir, [timestr '_nnmf_component_recon_' num2str(i, '%03d') '.png']), '-dpng', '-r600');
end
pause(2);
close all;

%% Save checkpoint
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': Saving post-nmf-recon checkpoint']);
save(fullfile(Input.outdir, [datestr(now, 'YYmmddTHHMM') '_checkpoint_post-nmf-recon.mat']), 'Input', 'SID_output','-v7.3');

%% filter reconstructed spatial filters
opts.border = [1,1,15];
opts.gpu_ids = Input.gpu_ids;
opts.axial = Input.axial;
if Input.optimize_kernel
    opts.neur_rad = 6;
else
    opts.neur_rad = Input.neur_rad;
end
opts.native_focal_plane = Input.native_focal_plane;

if Input.filter
    disp('Filtering reconstructed spatial filters');
    SID_output.segmm = filter_recon(SID_output.recon, opts);
else
    SID_output.segmm = SID_output.recon;
end

%% Segment reconstructed components
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': generate initial brain model'])

dim = [1 1 Input.axial];
SID_output.neuron_centers_ini = [];
SID_output.neuron_centers_per_component = {};
[~,u] = max([size(SID_output.segmm,1),size(SID_output.segmm,2)]);
for ii=1:size(SID_output.segmm,u)
    SID_output.neuron_centers_per_component{ii} = segment_component(SID_output.segmm{ii},Input.segmentation.threshold);
    num(ii) = size(SID_output.neuron_centers_per_component{ii},1); %#ok<AGROW>
    disp(['Component ' num2str(ii) ': Found ' num2str(num(ii)) ' neuron candidates']);
end

ids = isoutlier(num, 'ThresholdFactor', 10);
ids = (num > mean(num)) .* ids;
outlier_ixs = find(ids);

for i = 1 : numel(outlier_ixs)
    ii = outlier_ixs(i);
    threshold = 0.1;
    SID_output.neuron_centers_per_component{ii} = segment_component(SID_output.segmm{ii}, threshold);
    num(ii) = size(SID_output.neuron_centers_per_component{ii},1);
    disp(['Re-segmenting component with overly many neurons with higher threshold: Component ' num2str(ii) ': Found ' num2str(num(ii)) ' neuron candidates']);
end

% Merge closely spaced neuron candidates from different NNMF components by finding clusters of candidates that have an extent smaller than Input.neuron_rad
[SID_output.neuron_centers_ini, SID_output.neur_id] = iterate_cluster(SID_output.neuron_centers_per_component, Input.cluster_iter, Input.neur_rad, dim);

figure; histogram(SID_output.neuron_centers_ini(:,3), -0.5 : 1 : size(SID_output.recon{1},3) + 0.5);
xlabel('Z plane index');
ylabel('Neuron frequency');
print(fullfile(Input.outdir, [timestr '_segmm_z-hist.png']), '-dpng', '-r300');

if ~isfield(Input.segmentation,'top_cutoff')
    disp('Check the axial distribution and remove top/bottom artefacts');
    Input.segmentation.top_cutoff = input('Input top cutoff \n');
end
if ~isfield(Input.segmentation,'bottom_cutoff')
    Input.segmentation.bottom_cutoff = input('Input bottom cutoff \n');
end
id = logical((SID_output.neuron_centers_ini(:,3) >= Input.segmentation.top_cutoff) .* ...
             (SID_output.neuron_centers_ini(:,3) <= Input.segmentation.bottom_cutoff));
SID_output.neuron_centers_ini = SID_output.neuron_centers_ini(id,:);
SID_output.neur_id = SID_output.neur_id(id,:);

%% Plot segmentation result
timestr = datestr(now, 'YYmmddTHHMM');
for i = 1:numel(SID_output.segmm)
    figure('Position', [50 50 1200 600]);
    colormap parula;
    subplot(1, 4, 1:3);
    title(['Segmentation result for NNMF component ' num2str(i)]);
    hold on;
    imagesc(squeeze(max(SID_output.segmm{i}, [], 3)));
    scatter(SID_output.neuron_centers_per_component{i}(:,2), SID_output.neuron_centers_per_component{i}(:,1), 'r.');
    axis image;
    axis ij;
    colorbar;
    hold off;
    subplot(1, 4, 4);
    hold on;
    imagesc(squeeze(max(SID_output.segmm{i}, [], 2)));
    axis ij;
    scatter(SID_output.neuron_centers_per_component{i}(:,3), SID_output.neuron_centers_per_component{i}(:,1), 'r.');
    xlim([1 size(SID_output.segmm{i}, 3)]);
    ylim([1 size(SID_output.segmm{i}, 1)]);
    colorbar;
    print(fullfile(Input.outdir, [timestr '_segmm_segmentation_' num2str(i, '%03d') '.png']), '-dpng', '-r300');
end

%%
clearvars -except sensor_movie Input SID_output mean_signal psf_ballistic Hsize m sensor_movie_max sensor_movie_min dim;

%% Crop sensor movie
sensor_movie = sensor_movie(SID_output.idx,:);

%% Initiate forward_model
if ~isfield(Input,'use_std_GLL')
    Input.use_std_GLL = false;
end

if isempty(Input.gpu_ids)||Input.use_std_GLL
    SID_output.forward_model_ini=generate_LFM_library_CPU(SID_output.neuron_centers_ini, psf_ballistic, round(SID_output.neur_rad), dim, size(SID_output.recon{1}));
else
    opts = SID_output.recon_opts;
    opts.NumWorkers = 10;
    opts.image_size = SID_output.movie_size(1:2);
    opts.axial = Input.axial;
    opts.neur_rad = Input.neur_rad;
    SID_output.forward_model_ini = generate_LFM_library_GPU(SID_output.recon, SID_output.neuron_centers_ini, ...
                                                            round(SID_output.neur_id), psf_ballistic, opts);
end

%% Generate template
SID_output.template = generate_template(SID_output.neuron_centers_ini, psf_ballistic.H, SID_output.std_image, Input.template_threshold);

%% Remove neuron templates that don't have positive weights inside of to the overall crop region determined further up (based on crop_mask and/or crop_params)
neur = find(squeeze(max(SID_output.forward_model_ini(:, SID_output.idx), [], 2) > 0));
SID_output.forward_model_iterated = SID_output.forward_model_ini(neur, SID_output.idx);
SID_output.neuron_centers_iterated = SID_output.neuron_centers_ini(neur, :);
SID_output.indices_in_orig = neur;

template_ = SID_output.template(neur, SID_output.idx);
Nnum = psf_ballistic.Nnum;

%% Alternating bi-convex search (SID main demixing)
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Start optimizing SID model'])
tic

opts_spat = struct;
opts_spat.lamb_L1 = Input.SID_optimization_args.spatial_lamb_L1;
opts_spat.lamb_L2 = Input.SID_optimization_args.spatial_lamb_L2;
opts_spat.lamb_orth_L1 = Input.SID_optimization_args.spatial_lamb_orth_L1;

opts_temp = struct;
opts_temp.idx = SID_output.idx;
opts.temp.lambda = Input.SID_optimization_args.temporal_lambda;
opts_temp.microlenses = SID_output.microlenses;
opts_temp.use_std = Input.use_std;
opts_spat.use_std = Input.use_std;

opts_spat.bg_sub = Input.bg_sub;
opts_temp.bg_sub = Input.bg_sub;

if ~isempty(Input.gpu_ids')
    opts_temp.gpu_id = Input.gpu_ids(1);
end

if isfield(Input, 'bg_sub') && Input.bg_sub % && ~Input.use_std
    SID_output.forward_model_iterated(end+1,:) = SID_output.bg_spatial(SID_output.idx);
    SID_output.indices_in_orig = [SID_output.indices_in_orig' length(SID_output.indices_in_orig) + 1];
end

sensor_movie = double(sensor_movie);
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Starting temporal update']);
SID_output.forward_model_iterated = (1 ./ sqrt(sum(SID_output.forward_model_iterated .^ 2, 2))) ...
                                    .* SID_output.forward_model_iterated;
SID_output.timeseries_ini = LS_nnls(SID_output.forward_model_iterated(:,SID_output.microlenses(SID_output.idx)>0)', double(sensor_movie(SID_output.microlenses(SID_output.idx)>0,:)), opts_temp);
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Temporal update completed']);

SID_output.timeseries_iterated=SID_output.timeseries_ini;
toc

for iter=1:Input.num_iter
    disp([num2str(iter) '. iteration started']);

    [SID_output.timeseries_iterated, ...
     SID_output.forward_model_iterated, ...
     template_, ...
     SID_output.indices_in_orig] = spatial_SID_update(sensor_movie, ...
                                                      SID_output.timeseries_iterated, ...
                                                      SID_output.forward_model_iterated, ...
                                                      template_, ...
                                                      SID_output.indices_in_orig, ...
                                                      opts_spat);

    if isfield(Input, 'update_template') && Input.update_template
        if iter>=2
            for neuron=1:size(template_,1)
                cropp=zeros(size(SID_output.std_image));
                cropp(SID_output.idx)=template_(neuron,:);
                img=reshape(cropp,size(SID_output.std_image));
                img=conv2(img,ones(2*Nnum),'same')>0;
                img=img(:);
                template_(neuron,:)=(img(SID_output.idx)>0.1);
                disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' num2str(neuron)])
            end
        end
    end

    [SID_output.forward_model_iterated, ...
     SID_output.timeseries_iterated, template_, ...
     SID_output.indices_in_orig] = temporal_SID_update(sensor_movie, ...
                                                       SID_output.forward_model_iterated, ...
                                                       SID_output.timeseries_iterated, ...
                                                       template_, SID_output.indices_in_orig, opts_temp);

    [SID_output.forward_model_iterated, ...
     SID_output.timeseries_iterated, template_, ...
     SID_output.indices_in_orig] = merge_filters(SID_output.forward_model_iterated, ...
                                                 SID_output.timeseries_iterated, ...
                                                 template_, SID_output.indices_in_orig, opts_temp);
    disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Iteration ' num2str(iter) ' of ' num2str(Input.num_iter) ' completed']);
end
SID_output.neuron_centers_iterated = SID_output.neuron_centers_ini(SID_output.indices_in_orig(1:end-1), :);
SID_output.template_iterated = template_;
opts_temp.warm_start = [];
clear sensor_movie;
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'SID model optimization completed']);

%% Reconstruct final demixed NSFs
if Input.recon_final_spatial_filters
    opts = Input.recon_opts;
    opts.gpu_ids = Input.gpu_ids;
    forward_model = zeros(size(SID_output.forward_model_iterated,1), length(SID_output.std_image(:)));
    forward_model(:,SID_output.idx) = SID_output.forward_model_iterated;
    SID_output.recon_NSF = reconstruct_S(forward_model, psf_ballistic, opts);
end

%% Extract time series at location indir
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Extracting timeseries']);
opts_temp.warm_start=[];
opts_temp.outfile = fullfile(Input.outdir, 'timeseries_debug_out.mat');
opts_temp.do_crop = Input.do_crop;
opts_temp.crop = SID_output.crop;
tic
SID_output.timeseries_total = incremental_temporal_update_gpu(SID_output.forward_model_iterated, Input.indir, [], Input.ts_extract_chunk_size, Input.x_offset,Input.y_offset,Input.dx,Nnum,opts_temp);
toc
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Timeseries extraction complete']);

%% Sort by SNR
opts.bg_sub = Input.bg_sub;
n=SNR_order(SID_output.timeseries_total, opts);
SID_output.neuron_centers_iterated = SID_output.neuron_centers_iterated(n(1:end-Input.bg_sub),:);
SID_output.forward_model_iterated = SID_output.forward_model_iterated(n,:);
SID_output.timeseries_iterated = SID_output.timeseries_iterated(n,:);
SID_output.timeseries_total = SID_output.timeseries_total(n,:);
SID_output.indices_in_orig = SID_output.indices_in_orig(n);

%% Save SID_output
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'Saving result'])
SID_output.Input = Input;
save(fullfile(Input.outdir, Input.SID_output_name), 'Input', 'SID_output', '-v7.3');

%% Summary figure: NNMF MIPs, with centers overlaid as red dots
timestr = datestr(now, 'YYmmddTHHMM');
nmf_mip = SID_output.recon{1};
for i=2:numel(SID_output.recon)
    nmf_mip = max(nmf_mip, SID_output.recon{i});
end

figure('Position', [50 50 1200 600]);
colormap parula;
subplot(1, 4, 1:3);
hold on;
imagesc(squeeze(max(nmf_mip, [], 3)));
scatter(SID_output.neuron_centers_iterated(:,2), SID_output.neuron_centers_iterated(:,1), 'r.');
hold off;
axis image;
axis ij;
title([Input.SID_output_name ' - NNMF components MIPs, with segmentation centers'], 'Interpreter', 'none');
colorbar;
subplot(1,4,4)
hold on;
imagesc(squeeze(max(nmf_mip, [], 2)));
scatter(SID_output.neuron_centers_iterated(:,3), SID_output.neuron_centers_iterated(:,1), 'r.');
hold off;
axis ij;
xlim([1 size(SID_output.recon{i}, 3)]);
ylim([1 size(SID_output.recon{i}, 1)]);
colorbar;
print(fullfile(Input.outdir, [timestr '_nnmf_components_mip.png']), '-dpng', '-r300');

%% Plot timeseries heatmap, clustered
timestr = datestr(now, 'YYmmddTHHMM');
figure('Position', [50 50 1200 600]);
ts = zscore(SID_output.timeseries_iterated, 0, 2);
clustered_ixs = clusterdata(ts, 'criterion', 'distance', 'distance', 'correlation', 'maxclust', floor(size(ts,1)/10));
tsi = [clustered_ixs ts];
ts = sortrows(tsi);
ts = ts(2:end,:);
limits = [prctile(ts(:), 0.01), prctile(ts(:), 99.9)];
imagesc(ts, limits);
title([Input.SID_output_name ' - timeseries, z-scored, corr-clustered'], 'Interpreter', 'none');
colormap parula;
colorbar;
print(fullfile(Input.outdir, [timestr '_timeseries_zscore.png']), '-dpng', '-r300');

%% Plot timeseries, stacked (random subset if there are more than 100)
ts = zscore(SID_output.timeseries_iterated, 0, 2);
y_shift = 4;
clip = true;
if size(ts,1) > 100
    sel = randperm(size(ts,1), 100);
else
    sel = 1:size(ts,1);
end
nixs = 1:size(ts,1);
sel_nixs = nixs(sel);

figure('Position', [10 10 2000 2000]);
title([Input.SID_output_name ' - timeseries, z-scored'], 'Interpreter', 'none');
subplot(121);
hold on
for n_ix = 1:floor(numel(sel_nixs)/2)
    ax = gca();
    ax.ColorOrderIndex = 1;
    loop_ts = ts(sel_nixs(n_ix),:);
    if clip
        loop_ts(loop_ts > 3*y_shift) = y_shift;
        loop_ts(loop_ts < -3*y_shift) = -y_shift;
    end
    t = (0:size(ts,2)-1);
    plot(t, squeeze(loop_ts) + y_shift*(n_ix-1));
    text(30, y_shift*(n_ix-1), num2str(sel_nixs(n_ix)));
end
xlabel('Frame');
xlim([min(t) max(t)]);
hold off;
axis tight;
set(gca,'LooseInset',get(gca,'TightInset'))

subplot(122);
hold on;
for n_ix = ceil(numel(sel_nixs)/2):numel(sel_nixs)
    ax = gca();
    ax.ColorOrderIndex = 1;
    loop_ts = ts(sel_nixs(n_ix),:);
    if clip
        loop_ts(loop_ts > y_shift) = y_shift;
        loop_ts(loop_ts < -y_shift) = -y_shift;
    end
    t = (0:size(ts,2)-1);
    plot(t, squeeze(loop_ts) + y_shift*(n_ix-1));
    text(30, y_shift*(n_ix-1), num2str(sel_nixs(n_ix)));
end
xlabel('Frame');
xlim([min(t) max(t)]);
hold off;
axis tight;
set(gca,'LooseInset',get(gca,'TightInset'))
print(fullfile(Input.outdir, [timestr '_timeseries_zscore_stacked.png']), '-dpng', '-r300');

%% Inspect a random neuron footprint and associated timeseries
ix = randperm(size(SID_output.timeseries_iterated, 1), 1);
figure('Position', [20, 20, 2000, 2000]);
subplot(3,1,1:2);
forward_model_ix = zeros(size(SID_output.std_image));
forward_model_ix(SID_output.idx) = SID_output.forward_model_iterated(ix,:);
imagesc(forward_model_ix, [0 max(SID_output.forward_model_iterated(ix,:))]);
axis image;
colorbar();
subplot(3,1,3);
plot((1:size(SID_output.timeseries_iterated,2)), SID_output.timeseries_iterated(ix,:));
title(['Neuron candidate ' num2str(ix)]);

%% Delete cached psf file
if ~strcmp(Input.psf_cache_dir, '')
    disp([datestr(now,  'YYYY-mm-dd HH:MM:SS') ': Deleting cached psf file']);
    rmdir(Input.psf_cache_dir_unique, 's');
end

%%
disp([datestr(now, 'YYYY-mm-dd HH:MM:SS') ': ' 'main_nnmf_SID() returning'])

%%
end
