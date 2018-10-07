% MIT License
% 
% Copyright (c) 2017 The Scientific Computing and Imaging Institute
% 
% Permission is hereby granted, free of charge, to any person obtaining a copy
% of this software and associated documentation files (the "Software"), to deal
% in the Software without restriction, including without limitation the rights
% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
% copies of the Software, and to permit persons to whom the Software is
% furnished to do so, subject to the following conditions:
% 
% The above copyright notice and this permission notice shall be included in all
% copies or substantial portions of the Software.
% 
% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
% SOFTWARE.


function [beatEnvelopes, allFidsAbsFr, info, success] = oldVersion_getBeatsAndFids(unslicedComplPotvals,templateBeatEnvelope, templateFids, badLeads, settings)
% INPUTS:
%   - unslicedComplPotvals: the complete (all leads) and unsliced (not sliced into beats) potvals where want to find teh beats and fiducials
%     any preprocessing like temporal filtering should already be done
%   - templateBeatEnvelope: an array [beatStartFrame, beatEndFrame] with the start and endframe of the template beat
%   - templateFids: the usual ts.fids structure with the fields 'type' and 'value' that contains the template fids
%   - badleads: an array with all the leads in the potvals that are bad and should be discarded
%   - settings: a struct with all the settings that would normally be done by the user in the PFEIFER guidaf.
%     Settings musst have the following fields:
%           - numLeadsToBeFiducialised
%           - leadsOfAllGroups
%           - demandedLeads
%           - accuracy
%           - fidsKernelLength
%           - window_width
%           - DoIndivFids: a bool indicating if you want individual fids or only global fids
%           - autoUpdateKernels: a bool indicating if you want to update the template once every nBeatsBeforeUpdating
%           - nBeatsToAvrgOver:  an integer indicating over how many beats you want to average to get a new updated fiducial kernel.
%             This field is not needed if autoUpdateKernels == 0.
%           - nBeatsBeforeUpdating: an integer indicating how often (after how many beats) you want to update the fiducial kernel
%             This field is not needed if autoUpdateKernels == 0.



%%%% initialize outputs and some other stuff
beatEnvelopes = {};
allLocFrFids = {};
success = 0;
nLeads = size(unslicedComplPotvals,1);
nFrames = size(unslicedComplPotvals,2);
bsk = templateBeatEnvelope(1);
bek = templateBeatEnvelope(2);



%%%% get all the badleads or blanked leads in unslicedPotvals
blankedLeads = [];
for leadIdx=1:nLeads
    if nnz(unslicedComplPotvals(leadIdx,1:50:end)) == 0
        blankedLeads(end+1) = leadIdx;
    end
end
leadsToBeIgnored = union(badLeads, blankedLeads);


%%%% get the RMS of unslicedPotvals
leadsForRMS = setdiff(settings.leadsOfAllGroups, badLeads);
rmsSignal = preprocessPotvals(unslicedComplPotvals(leadsForRMS,:));

%%%% get the beatEnvelopes
beatEnvelopes = getBeatEnvelopes(rmsSignal, rmsSignal(bsk:bek), settings.accuracy,bsk);

% find oriBeatIdx, the index of the template beat
oriBeatIdx = [];
for beatIdx=1:length(beatEnvelopes)    
    if (abs(beatEnvelopes{beatIdx}(1)-bsk)) < 3  % if found beat "close enough" to original Beat 
        oriBeatIdx = beatIdx;
        break
    end
end
beatEnvelopes = beatEnvelopes(oriBeatIdx:end);   % get rid if beats occuring before the user fiducialized beat
nBeats = length(beatEnvelopes);


%%%% get the fiducials to be done
[fidTypes, relFrOriFidsValues] = getFidsTypesAndValuesFromFids(templateFids);
absFrOriFidsValues = relFrOriFidsValues + bsk - 1;
nFids=length(fidTypes);


%%%% get the fsk and fek
fsk=absFrOriFidsValues - settings.fidsKernelLength;   % fiducial start kernel,  the index in potvals where the kernel for fiducials starts
fek=absFrOriFidsValues + settings.fidsKernelLength;   % analog to fsk, but 'end'
% make sure kernel not out of range..
for fidIdx = 1:length(fidTypes)
    if fsk(fidIdx) < 1  % if kernel 'to far left', shift it to the right!
        shift = - fsk(fidIdx) + 1;
        fsk(fidIdx) = 1;
        fek(fidIdx) = fek(fidIdx) + shift;
    elseif fek(fidIdx) > nFrames  % if kernel 'to far right', shift it to the left!
        shift = nFrames - fek(fidIdx);
        fsk(fidIdx) = fsk(fidIdx) + shift;
        fek(fidIdx) = nFrames;
    end
end


%%%% set up leadsToAutofiducialize
if settings.DoIndivFids
   leadsToAutofiducialize = setdiff(settings.leadsOfAllGroups, leadsToBeIgnored);
   nLeadsToAutofiducialize = length(leadsToAutofiducialize);
else
    nLeadsToAutofiducialize = settings.nToBeFiducialized;
    leadsToAutofiducialize = getleadsToAutofiducialize(nLeadsToAutofiducialize, settings.leadsOfAllGroups, settings.demandedLeads, leadsToBeIgnored);
end


%%%% reduce potvals, add rms 
unslicedReducedPotvals = unslicedComplPotvals(leadsToAutofiducialize,:);
clear unslicedComplPotvals
if settings.USE_RMS
    unslicedReducedPotvals(end+1,:) = rmsSignal;
    nLeadsToAutofiducialize = nLeadsToAutofiducialize + 1;
end



%%%% set up the kernels
totalKernelLength = 2 * settings.fidsKernelLength +1;
fidKernel = zeros(nLeadsToAutofiducialize, totalKernelLength, nFids);
for fidIdx = 1:nFids
    fidKernel(:,:,fidIdx) = unslicedReducedPotvals(:,fsk(fidIdx):fek(fidIdx));
end





%%%% initialize/preallocate allFidsAbsFrame
if nFids > 0
    defaultFidStruct(nFids) = struct('type',[],'value',[],'variance',[]);
else
    defaultFidStruct = struct('type',[],'value',[],'variance',[]);
end
[allFidsAbsFr{1:nBeats}] = deal(defaultFidStruct);

%%%%%%%%%%%%% fill AllFids with values %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
h=waitbar(0,'Autofiducializing Beats..');
for beatIdx=1:nBeats %for each beat
    bs = beatEnvelopes{beatIdx}(1);  % start of beat
    be = beatEnvelopes{beatIdx}(2);  % end of beat
    
    
    %%%%% check if it is time to update beat/fiducial kernels and relFrOriFidsValues. Do it if that's the case
    if settings.autoUpdateKernels
        if mod(beatIdx - 1, settings.nBeatsBeforeUpdating) == 0 && beatIdx~= 1   %if it is time to update the kernels (and it is not the first beat)
            beatAvrgIdxs = (beatIdx - settings.nBeatsToAvrgOver):(beatIdx - 1);   % the indeces of the beats to use for averaging
            
            oldRelFrOriFidsValues = relFrOriFidsValues;
            [fidKernel, relFrOriFidsValues] = getNewKernelsAndRelFrFidValues(unslicedReducedPotvals, allFidsAbsFr(beatAvrgIdxs), beatEnvelopes(beatAvrgIdxs), fidTypes, settings.fidsKernelLength);
            [beatKernel, relFrOriFidsValues] = getNewBeatKernel(rmsSignal,beatEnvelopes(beatAvrgIdxs),fidTypes, oldRelFrOriFidsValues, relFrOriFidsValues);
        end
    end
    
    
    %%%% loop through fiducials and get the values
    for fidIdx=1:nFids        
        %%%% set up windows
        ws = bs - 1 + relFrOriFidsValues(fidIdx) - settings.window_width;  % dont search complete beat, only around fid
        we = bs - 1 + relFrOriFidsValues(fidIdx) + settings.window_width; 
        if ws < bs  % if window 'to far left', shift it to the right!
            shift = bs - ws;
            ws = bs;
            we = we + shift;
        elseif we > be  % if window 'to far right', shift it to the left!
            shift = be - we;
            ws = ws + shift;
            we = be;
        end
        windows=unslicedReducedPotvals(:,ws:we);

        
        %%%% find fiducials
        [winFrGlobFid, winFrIndivFids, variance] = findFid(windows,fidKernel(:,:,fidIdx));
        
        %%%% don't put the RMS in output as it only causes trouble with plotting and stuff.. only include it in averaging to find global fid
        if settings.USE_RMS
            winFrIndivFids(end)=[];
        end
        
        
        %put fids in absolute frame
        absFrIndivFids = winFrIndivFids + absFrOriFidsValues(fidIdx) - fsk(fidIdx) + ws - 1;  % now  newIndivFids is in "complete potvals" frame. 
        absFrGlobFids = winFrGlobFid + absFrOriFidsValues(fidIdx) - fsk(fidIdx) + ws - 1;      % put it into "complete potvals" frame
        
        
        %%%% if DoIndivFids, set individual fids of unfiducialized leads to beat start
        if settings.DoIndivFids
            copy_absFrIndivFids = absFrIndivFids;
            absFrIndivFids = zeros(nLeads,1);
            absFrIndivFids(leadsToAutofiducialize) = copy_absFrIndivFids;
            absFrIndivFids(absFrIndivFids == 0) = 1;
        end
        

        %%%% put the found absFrIndivFids in allFids
        allFidsAbsFr{beatIdx}(fidIdx).type=fidTypes(fidIdx);
        allFidsAbsFr{beatIdx}(fidIdx).value=absFrIndivFids;
        
        %%%% add the global fid to allFids
        allFidsAbsFr{beatIdx}(nFids+fidIdx).type=fidTypes(fidIdx);
        allFidsAbsFr{beatIdx}(nFids+fidIdx).value=absFrGlobFids;  
        allFidsAbsFr{beatIdx}(nFids+fidIdx).variance=variance;
        
    end
    if isgraphics(h), waitbar(beatIdx/nBeats,h), end
end
if isgraphics(h), delete(h), end


%%%% put some information about the autoprocessing in 'info'
info.leadsToAutofiducialize = leadsToAutofiducialize;

success = 1;




function rmsSignal = preprocessPotvals(potvals)
% do temporal filter and RMS, to get a signal to work with

%%%% temporal filter
A = 1;
B = [0.03266412226059 0.06320942361376 0.09378788647083 0.10617422096837 0.09378788647083 0.06320942361376 0.03266412226059];

D = potvals';
D = filter(B,A,D);
D(1:(max(length(A),length(B))-1),:) = ones(max(length(A),length(B))-1,1)*D(max(length(A),length(B)),:);
potvals = D';

%%%% do RMS
rmsSignal=sqrt(mean(potvals.^2));
rmsSignal=rmsSignal-min(rmsSignal);












