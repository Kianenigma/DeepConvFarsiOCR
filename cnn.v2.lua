require 'dp'
require 'cutorch'
require 'cunn'

-- th -i mnist.v2.lua --cuda --progress  --momentum .7 --lecunlcn --batchNorm
--[[command line arguments]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Persian OCR using Convolution Neural Network Training/Optimization')
cmd:text('Example:')
cmd:text('$> th cnn.v2.lua --batchSize 128 --momentum 0.5')
cmd:text('Options:')
cmd:option('--learningRate', 0.1, 'learning rate at t=0')
cmd:option('--id', 'unNamedExperiment', 'name of the experiment passed to dp. loges will be saved under this name')
cmd:option('--lrDecay', 'linear', 'type of learning rate decay : adaptive | linear | schedule | none')
cmd:option('--minLR', 0.00001, 'minimum learning rate')
cmd:option('--saturateEpoch', 300, 'epoch at which linear decayed LR will reach minLR')
cmd:option('--schedule', '{}', 'learning rate schedule')
cmd:option('--maxWait', 4, 'maximum number of epochs to wait for a new minima to be found. After that, the learning rate is decayed by decayFactor.')
cmd:option('--decayFactor', 0.001, 'factor by which learning rate is decayed for adaptive decay.')
cmd:option('--maxOutNorm', 1, 'max norm each layers output neuron weights')
cmd:option('--momentum', 0, 'momentum')
cmd:option('--channelSize', '{64,128}', 'Number of output channels for each convolution layer.')
cmd:option('--kernelSize', '{5,5,5,5}', 'kernel size of each convolution layer. Height = Width')
cmd:option('--kernelStride', '{1,1,1,1}', 'kernel stride of each convolution layer. Height = Width')
cmd:option('--poolSize', '{2,2,2,2}', 'size of the max pooling of each convolution layer. Height = Width')
cmd:option('--poolStride', '{2,2,2,2}', 'stride of the max pooling of each convolution layer. Height = Width')
cmd:option('--padding', false, 'add math.floor(kernelSize/2) padding to the input of each convolution')
cmd:option('--batchSize', 64, 'number of examples per batch')
cmd:option('--cuda', false, 'use CUDA')
cmd:option('--useDevice', 1, 'sets the device (GPU) to use')
cmd:option('--maxEpoch', 200, 'maximum number of epochs to run')
cmd:option('--maxTries', 30, 'maximum number of epochs to try to find a better local minima for early-stopping')
cmd:option('--metaPath', '.', 'Where to cache meta data')
cmd:option('--cacheMode', 'writeonce', 'cache mode of FaceDetection (see SmallImageSource constructor for details)')
cmd:option('--loadSize', '', 'Image size')
cmd:option('--standardize', false, 'apply Standardize preprocessing')
cmd:option('--zca', false, 'apply Zero-Component Analysis whitening')
cmd:option('--lecunlcn', false, 'apply Yann LeCun Local Contrast Normalization (recommended)')
cmd:option('--activation', 'Tanh', 'transfer function like ReLU, Tanh, Sigmoid')
cmd:option('--hiddenSize', '{2048.1024,512,256}', 'size of the dense hidden layers after the convolution')
cmd:option('--batchNorm', false, 'use batch normalization. dropout is mostly redundant with this')
cmd:option('--dropout', false, 'use dropout')
cmd:option('--dropoutProb', '{0.2,0.5,0.5}', 'dropout probabilities')
cmd:option('--accUpdate', false, 'accumulate gradients inplace')
cmd:option('--progress', false, 'print progress bar')
cmd:option('--silent', false, 'dont print anything to stdout')
cmd:text()
opt = cmd:parse(arg or {})
if not opt.silent then
   table.print(opt)
end

opt.channelSize = table.fromString(opt.channelSize)
opt.kernelSize = table.fromString(opt.kernelSize)
opt.kernelStride = table.fromString(opt.kernelStride)
opt.poolSize = table.fromString(opt.poolSize)
opt.poolStride = table.fromString(opt.poolStride)
opt.dropoutProb = table.fromString(opt.dropoutProb)
opt.hiddenSize = table.fromString(opt.hiddenSize)
opt.loadSize = opt.loadSize:split(',')
for i = 1, #opt.loadSize do
   opt.loadSize[i] = tonumber(opt.loadSize[i])
end

--[[preprocessing]]--
local input_preprocess = {}
if opt.standardize then
   table.insert(input_preprocess, dp.Standardize())
end
if opt.zca then
   table.insert(input_preprocess, dp.ZCA())
end
if opt.lecunlcn then
   table.insert(input_preprocess, dp.GCN())
   table.insert(input_preprocess, dp.LeCunLCN{progress=true})
end

--[[data]]--

print("Loading dataset...")
ds = dofile 'cnn.v2.data.source.lua'

--[[Model]]--
cnn = nn.Sequential()

-- convolutional and pooling layers
depth = 1
inputSize = ds:imageSize('c') or opt.loadSize[1]
for i=1,#opt.channelSize do
   if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
      -- dropout can be useful for regularization
      cnn:add(nn.SpatialDropout(opt.dropoutProb[depth]))
   end
   cnn:add(nn.SpatialConvolution(
      inputSize, opt.channelSize[i],
      opt.kernelSize[i], opt.kernelSize[i],
      opt.kernelStride[i], opt.kernelStride[i],
      opt.padding and math.floor(opt.kernelSize[i]/2) or 0
   ))
   if opt.batchNorm then
      -- batch normalization can be awesome
      cnn:add(nn.SpatialBatchNormalization(opt.channelSize[i]))
   end
   cnn:add(nn[opt.activation]())
   if opt.poolSize[i] and opt.poolSize[i] > 0 then
      cnn:add(nn.SpatialMaxPooling(
         opt.poolSize[i], opt.poolSize[i],
         opt.poolStride[i] or opt.poolSize[i],
         opt.poolStride[i] or opt.poolSize[i]
      ))
   end
   inputSize = opt.channelSize[i]
   depth = depth + 1
end

-- get output size of convolutional layers
outsize = cnn:outside{1,ds:imageSize('c'),ds:imageSize('h'),ds:imageSize('w')}
inputSize = outsize[2]*outsize[3]*outsize[4]
dp.vprint(not opt.silent, "input to dense layers has: "..inputSize.." neurons")

cnn:insert(nn.Convert(ds:ioShapes(), 'bchw'), 1)

-- dense hidden layers
cnn:add(nn.Collapse(3))
for i,hiddenSize in ipairs(opt.hiddenSize) do
   if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
      cnn:add(nn.Dropout(opt.dropoutProb[depth]))
   end
   cnn:add(nn.Linear(inputSize, hiddenSize))
   if opt.batchNorm then
      cnn:add(nn.BatchNormalization(hiddenSize))
   end
   cnn:add(nn[opt.activation]())
   inputSize = hiddenSize
   depth = depth + 1
end

-- output layer
if opt.dropout and (opt.dropoutProb[depth] or 0) > 0 then
   cnn:add(nn.Dropout(opt.dropoutProb[depth]))
end

cnn:add(nn.Linear(inputSize, #(ds:classes())))
cnn:add(nn.LogSoftMax())

-- [[Propagators]]--
if opt.lrDecay == 'adaptive' then
   ad = dp.AdaptiveDecay{max_wait = opt.maxWait, decay_factor=opt.decayFactor}
elseif opt.lrDecay == 'linear' then
   opt.decayFactor = (opt.minLR - opt.learningRate)/opt.saturateEpoch
end

train = dp.Optimizer{
   acc_update = opt.accUpdate,
   loss = nn.ModuleCriterion(nn.ClassNLLCriterion(), nil, nn.Convert()),
   epoch_callback = function(model, report) -- called every epoch
      if report.epoch > 0 then
         if opt.lrDecay == 'adaptive' then
            opt.learningRate = opt.learningRate*ad.decay
            ad.decay = 1
         elseif opt.lrDecay == 'schedule' and opt.schedule[report.epoch] then
            opt.learningRate = opt.schedule[report.epoch]
         elseif opt.lrDecay == 'linear' then
            opt.learningRate = opt.learningRate + opt.decayFactor
         end
         opt.learningRate = math.max(opt.minLR, opt.learningRate)
         if not opt.silent then
            print("learningRate", opt.learningRate)
         end
      end
   end,
   callback = function(model, report) -- called every batch
      -- the ordering here is important
      if opt.accUpdate then
         model:accUpdateGradParameters(model.dpnn_input, model.output, opt.learningRate)
      else
         model:updateGradParameters(opt.momentum) -- affects gradParams
         model:updateParameters(opt.learningRate) -- affects params
      end
      model:maxParamNorm(opt.maxOutNorm) -- affects params
      model:zeroGradParameters() -- affects gradParams
   end,
   feedback = dp.Confusion(),
   sampler = dp.ShuffleSampler{batch_size = opt.batchSize},
   progress = opt.progress
}
valid = ds:validSet() and dp.Evaluator{
   feedback = dp.Confusion(),
   sampler = dp.Sampler{batch_size = opt.batchSize}
}
test = ds:testSet() and dp.Evaluator{
   feedback = dp.Confusion(),
   sampler = dp.Sampler{batch_size = opt.batchSize}
}

--[[Experiment]]--
xp = dp.Experiment{
   model = cnn,
   optimizer = train,
   validator = ds:validSet() and valid,
   id = dp.ObjectID.new(opt.id),
   tester = ds:testSet() and test,
   observer = {
      dp.FileLogger(),
      dp.EarlyStopper{
         error_report = {'validator','feedback','confusion','accuracy'},
         maximize = true,
         max_epochs = opt.maxTries
      },
      ad
   },
   random_seed = os.time(),
   max_epoch = opt.maxEpoch
}

--[[GPU or CPU]]--
if opt.cuda then
   require 'cutorch'
   require 'cunn'
   cutorch.setDevice(opt.useDevice)
   xp:cuda()
end

if not opt.silent then
   print"Model:"
   print(cnn)
end
xp:verbose(not opt.silent)

xp:run(ds)
