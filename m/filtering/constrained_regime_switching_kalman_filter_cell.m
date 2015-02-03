function [loglik,Incr,retcode,Filters]=constrained_regime_switching_kalman_filter_cell(...
    syst,data_info,state_trend,init,options)
% H1 line
%
% Syntax
% -------
% ::
%
% Inputs
% -------
%
% Outputs
% --------
%
% More About
% ------------
%
% Examples
% ---------
%
% See also: 


% this filter assumes a state space of the form
% X_t=c_t{st}+T{st}*X_{t-1}+R{st}*eps_t
% y_t=d_t{st}+Z*X_t+eta_t
% where c_t{st} and d_t{st} are, possibly time-varying, deterministic terms
% the covariance matrices can be time-varying

% data
%-----
data_structure=data_info.data_structure;
include_in_likelihood=data_info.include_in_likelihood;
no_more_missing=data_info.no_more_missing;
obs_id=data_info.varobs_id;
data=data_info.y;
% N.B: data_info also contains x, the observations on the exogenous
% variables (trend, etc). But those observations will come through
% data_trend and so are not used directly in the filtering function.

% state matrices
%---------------
T=syst.T;
R=syst.R;
H=syst.H;
Qfunc=syst.Qfunc;
sep_compl=syst.sep_compl;
cond_shocks_id=syst.anticipated_shocks;

% initial conditions
%-------------------
a=init.a;
P=init.P;
PAItt=init.PAI00;
RR=init.RR;

% free up memory
%---------------
clear data_info syst init

Q=Qfunc(a{1});
PAI=transpose(Q)*PAItt;

% matrices' sizes
%----------------
[p0,smpl]=size(data);
smpl=min(smpl,find(include_in_likelihood,1,'last'));
m=size(T{1},1);
h=numel(T);
[~,exo_nbr,horizon]=size(R{1});
nshocks=exo_nbr*horizon;
shocks=zeros(exo_nbr,horizon);

h_last=0;
if ~isempty(H{1})
    h_last=size(H{1},3);
end
rqr_last=size(RR{1},3);
if rqr_last>1
    error('time-varying impact matrices not supported in this filter')
end

% definitions and options
%------------------------
twopi=2*pi;
store_filters=options.kf_filtering_level;
if store_filters
    nsteps=options.kf_nsteps;
else
    % do not do multi-step forecasting during estimation
    nsteps=1;
end
kalman_tol=options.kf_tol;

% re-create the steady state
%----------------------------
ss=cell(1,h);
Im=eye(m);
for st=1:h
    ss{st}=(Im-T{st})\state_trend{st}(:,1);
    if any(any(abs(state_trend{st}(:,2:end)-state_trend{st}(:,1:end-1))))>1e-9
        error('this filtering algorithm is not ready for deterministic terms')
    end
    if store_filters
        % resize everything: T=[T 0;0 0], R=[R;eye()]; a=[a;0]; P=[P,0;0 eye()]
        %----------------------------------------------------------------------
        ss{st}=[ss{st};zeros(nshocks,1)];
        T{st}=[T{st},zeros(m,nshocks)
            zeros(nshocks,m+nshocks)];
        if st==1
            Rproto=[R{1}(:,:)
                eye(nshocks)];
            % store R for every period
            %--------------------------
            R_store=struct();
            RR0=RR;
        end
        RR{st}=[RR{st},R{st}(:,:);
            R{st}(:,:).',eye(nshocks)];
        Rproto(1:m,:)=R{st}(:,:);
        R{st}=reshape(Rproto,[m+nshocks,exo_nbr,horizon]);
        a{st}=[a{st};zeros(nshocks,1)];
        P{st}=[P{st},zeros(m,nshocks)
            zeros(nshocks,m),eye(nshocks)];
        if st==h
            clear Rproto
        end
    end
end
clear state_trend
if store_filters
    % update size and keep a copy
    m_orig=m;
    m=size(T{1},1);
end
% time-varying R matrix
%-----------------------
Rt=cell(1,h);

% few transformations
%--------------------
Tt=T;
any_T=false(1,m);
for st=1:h
    Tt{st}=transpose(T{st}); % permute(T,[2,1,3]); % transpose
    any_T=any_T|any(abs(T{st})>1e-9,1);
end

% free up memory
%---------------
% M=rmfield(M,{'data','T','data_structure','include_in_likelihood',...
%     'data_trend','state_trend','t_dc_last','obs_id','a','P','Q','PAI00','H','RR'});


% initialization of matrices
%-----------------------------
loglik=[];
Incr=nan(smpl,1);

if store_filters>2
    K_store=[];
    iF_store=[];
    v_store=[];
end
Filters=initialize_storage();

oldK=inf;
PAI01y=nan(h,1);
twopi_p_dF=nan(1,h);
% the following elements change size depending on whether observations are
% missing or not and so it is better to have them in cells rather than
% matrices
iF=cell(1,h);
v=cell(1,h);
% This also changes size but we need to assess whether we reach the steady state fast or not
K=zeros(m,p0,h); % <---K=cell(1,h);

% no problem
%-----------
retcode=0;
is_steady=false;

% disp(['do not forget to test whether it is possible to reach the steady ',...
%     'state with markov switching'])

for t=1:smpl% <-- t=0; while t<smpl,t=t+1;
    % data and indices for observed variables at time t
    %--------------------------------------------------
    occur=data_structure(:,t);
    p=sum(occur); % number of observables to be used in likelihood computation
    y=data(occur,t);
    obsOccur=obs_id(occur); %<-- Z=M.Z(occur,:);
    
    likt=0;
    for st=1:h
        % forecast of observables: already include information about the
        % trend and or the steady state from initialization
        %------------------------------------------------------------------
        yf=a{st}(obsOccur); %<-- yf=Z*a{st};
        
        % forecast errors and variance
        %-----------------------------
        v{st}=y-yf;
        
        if ~is_steady
            PZt=P{st}(:,obsOccur); % PZt=<-- P{st}*Z';
            
            Fst=PZt(obsOccur,:); % <--- F=Z*PZt+H{st}(occur,occur);
            if h_last>0
                Fst=Fst+H{st}(occur,occur,min(t,h_last));
            end
            detF=det(Fst);
            failed=detF<=0;
            if ~failed
                iF{st}=Fst\eye(p);
                failed=any(isnan(iF{st}(:)));
            end
            if failed
                retcode=305;
                return
            end
            
            % Kalman gain (for update)
            %-------------------------
            K(:,occur,st)=PZt*iF{st}; % K=PZt/F{st};
            
            % state covariance update (Ptt=P-P*Z*inv(F)*Z'*P)
            %------------------------------------------------
            P{st}=P{st}-K(:,occur,st)*PZt.';%<---P{st}=P{st}-K(:,occur,st)*P{st}(obsOccur,:);
            
            twopi_p_dF(st)=twopi^p*detF;
        end
        % state update (att=a+K*v)
        %-------------------------
        a{st}=a{st}+K(:,occur,st)*v{st};
        
        f01=(twopi_p_dF(st)*exp(v{st}'*iF{st}*v{st}))^(-0.5);
        PAI01y(st)=PAI(st)*f01;
        likt=likt+PAI01y(st);
    end
    
    % Probability updates
    %--------------------
    PAI01_tt=PAI01y/likt;
    if likt<kalman_tol && (any(isnan(PAI01_tt))||any(isinf(PAI01_tt)))
        retcode=306;
        return
    end
    PAItt=sum(PAI01_tt,2);
    
    if store_filters>1
        store_updates();
    end
    
    % Likelihood computation
    %-----------------------
    Incr(t)=log(likt);
    
    % endogenous probabilities (conditional on time t information)
    %-------------------------------------------------------------
    att=a;
    if ~is_steady
        Ptt=P;
    end
    
    [Q,retcode]=Qfunc(att{1});
        if retcode
            return
        end
    
    % Probabilities predictions
    %--------------------------
    if h>1
        PAI=Q'*PAItt;
    end
    
    % state and state covariance prediction
    %--------------------------------------
    for splus=1:h
        a{splus}=zeros(m,1);
        if ~is_steady
            P{splus}=zeros(m);
        end
        for st=1:h
            if h==1
                pai_st_splus=1;
            else
                pai_st_splus=Q(st,splus)*PAItt(st)/PAI(splus);
            end
            a{splus}=a{splus}+pai_st_splus*att{st};
            if ~is_steady
                P{splus}=P{splus}+pai_st_splus*Ptt{st};
            end
        end
        [a{splus},iter]=do_one_step_forecast(T{splus},R{splus}(:,:),a{splus},ss{splus},...
            shocks,sep_compl,cond_shocks_id);
        if ~is_steady
            RR_splus=RR0{splus};
            if store_filters
                Rt{splus}=R{splus};
                Rt{splus}(1:m_orig,:,iter+2:end)=0;
                RR_splus=Rt{splus}(:,:)*Rt{splus}(:,:).'; 
            end
            P{splus}=T{splus}(:,any_T)*P{splus}(any_T,any_T)*Tt{splus}(any_T,:)+RR_splus;
            %             P{splus}=T{splus}(:,any_T)*P{splus}(any_T,any_T)*Tt{splus}(any_T,:)+RR{splus}(:,:,min(t,rqr_last));
            P{splus}=utils.cov.symmetrize(P{splus});
        end
    end
    
    if store_filters>0
        store_predictions()
        if store_filters>2
            R_store(t).R=Rt;
        end
    end
    
    if ~is_steady % && h==1
        [is_steady,oldK]=utils.filtering.check_steady_state_kalman(...
            is_steady,K,oldK,options,t,no_more_missing);
    end
end

% included only if in range
loglik=sum(Incr(include_in_likelihood));

if store_filters>2 % store smoothed
    r=zeros(m,h);
    ZZ=eye(m);
    ZZ=ZZ(obs_id,:);
    for t=smpl:-1:1
        Q=Filters.Q(:,:,t);
        occur=data_structure(:,t);
        obsOccur=obs_id(occur); %<-- Z=M.Z(occur,:);
        Z=ZZ(occur,:);
        y=data(occur,t);
        for s0=1:h
            for s1=1:h
                % joint probability of s0 (today) and s1 (tomorrow)
                if t==smpl
                    pai_0_1=Q(s0,s1)*Filters.PAItt(s0,t);
                else
                    pai_0_1=Q(s0,s1)*Filters.PAItt(s0,t)*...
                        Filters.PAItT(s1,t+1)/Filters.PAI(s1,t+1);
                end
                % smoothed probabilities
                %-----------------------
                Filters.PAItT(s0,t)=Filters.PAItT(s0,t)+pai_0_1;
            end
            % smoothed state and shocks
            %--------------------------
            [Filters.atT{s0}(:,1,t),Filters.eta{s0}(:,1,t),r(:,s0)]=...
                utils.filtering.smoothing_step(Filters.a{s0}(:,1,t),r(:,s0),...
                K_store{s0}(:,occur,t),Filters.P{s0}(:,:,t),T{s0},...
                R_store(t).R{s0}(:,:),Z,iF_store{s0}(occur,occur,t),...
                v_store{s0}(occur,t));
            % smoothed measurement errors
            %--------------------------
            Filters.epsilon{s0}(occur,1,t)=y-Filters.atT{s0}(obsOccur,1,t);
        end
        % correction for the smoothed probabilities [the approximation involved does not always work
        % especially when dealing with endogenous switching.
        SumProbs=sum(Filters.PAItT(:,t));
        if abs(SumProbs-1)>1e-8
            Filters.PAItT(:,t)=Filters.PAItT(:,t)/SumProbs;
        end
    end
end

% let's play squash
%-------------------
if store_filters
    for st=1:h
        % in terms of shocks we only save the first-step forecast
        [Filters.a{st},Filters.P{st},Filters.eta_tlag{st}]=...
            utils.filtering.squasher(Filters.a{st},Filters.P{st},m_orig);
        if store_filters>1
            [Filters.att{st},Filters.Ptt{st},Filters.eta_tt{st}]=...
                utils.filtering.squasher(Filters.att{st},Filters.Ptt{st},m_orig);
            if store_filters>2
%                 if st==1
%                     old_eta=Filters.eta;
%                 end
                [Filters.atT{st},Filters.PtT{st},Filters.eta{st}]=...
                    utils.filtering.squasher(Filters.atT{st},Filters.PtT{st},m_orig);
            end
        end
    end
end

    function store_updates()
        Filters.PAItt(:,t)=PAItt;
        for st_=1:h
            Filters.att{st_}(:,1,t)=a{st_};
            Filters.Ptt{st_}(:,:,t)=P{st_};
            if store_filters>2
                K_store{st_}(:,occur,t)=K(:,occur,st_);
                iF_store{st_}(occur,occur,t)=iF{st_};
                v_store{st_}(occur,t)=v{st_};
            end
        end
    end
    function store_predictions()
        Filters.PAI(:,t+1)=PAI;
        Filters.Q(:,:,t+1)=Q;
        for splus_=1:h
            Filters.a{splus_}(:,1,t+1)=a{splus_};
            Filters.P{splus_}(:,:,t+1)=P{splus_};
            for istep_=2:nsteps
                % this assumes that we stay in the same state and we know
                % we will stay. The more general case where we can jump to
                % another state is left to the forecasting routine.
                Filters.a{splus_}(:,istep_,t+1)=do_one_step_forecast(T{splus_},R{splus_}(:,:),...
                    Filters.a{splus_}(:,istep_-1,t+1),ss{splus_},shocks,...
                    sep_compl,cond_shocks_id);
            end
        end
    end
    function Filters=initialize_storage()
        Filters=struct();
        if store_filters>0 % store filters
            Filters.a=repmat({zeros(m,nsteps,smpl+1)},1,h);
            Filters.P=repmat({zeros(m,m,smpl+1)},1,h);
            for state=1:h
                Filters.a{state}(:,1,1)=a{state};
                Filters.P{state}(:,:,1)=P{state};
            end
            Filters.PAI=zeros(h,smpl+1);
            Filters.PAI(:,1)=PAI;
            for istep=2:nsteps
                % in steady state, we remain at the steady state
                %------------------------------------------------
                for state=1:h
                    Filters.a{state}(:,istep,1)=Filters.a{state}(:,istep-1,1);
                end
            end
            Filters.Q=zeros(h,h,smpl+1);
            Filters.Q(:,:,1)=Q;
            if store_filters>1 % store updates
                Filters.att=repmat({zeros(m,1,smpl)},1,h);
                Filters.Ptt=repmat({zeros(m,m,smpl)},1,h);
                Filters.PAItt=zeros(h,smpl);
                if store_filters>2 % store smoothed
                    K_store=repmat({zeros(m,p0,smpl)},1,h);
                    iF_store=repmat({zeros(p0,p0,smpl)},1,h);
                    v_store=repmat({zeros(p0,smpl)},1,h);
                    Filters.atT=repmat({zeros(m,1,smpl)},1,h);
                    Filters.PtT=repmat({zeros(m,m,smpl)},1,h);
                    Filters.eta=repmat({zeros(exo_nbr*horizon,1,smpl)},1,h); % smoothed shocks
                    Filters.epsilon=repmat({zeros(p0,1,smpl)},1,h); % smoothed measurement errors
                    Filters.PAItT=zeros(h,smpl);
                end
            end
        end
    end
end

function [y1,iter]=do_one_step_forecast(T,R,y0,ss,shocks,compl,cond_shocks_id)
% y1: forecast
% iter : number of shock periods required to satisfy the constraints.
order=1; % order of approximation
sig=1; % perturbation coefficient note it has been mixed with the steady state
m=size(T,2);
% add a column for the perturbation coefficient and put into a cell
T={[T,zeros(m,1),R(:,:)]};
xloc=1:m;
y0=struct('y',y0);
[y1,iter]=utils.forecast.one_step(T,y0,ss,xloc,sig,shocks,order,compl,cond_shocks_id);
y1=y1.y;
end