function [Results]=mh_sampler(logf,lb,ub,options,mu,SIG_mom)
% MH_SAMPLER -- Metropolis Hastings sampler
%
% Syntax
% -------
% ::
%
%   [Results]=MH_SAMPLER(logf,lb,ub)
%
%   [Results]=MH_SAMPLER(logf,lb,ub,options)
%
%   [Results]=MH_SAMPLER(logf,lb,ub,options,mu)
%
%   [Results]=MH_SAMPLER(logf,lb,ub,options,mu,SIG)
%
% Inputs
% -------
%
% - **logf** [char|function_handle]: Objective function to MINIMIZE!!!
%
% - **lb** [d x 1 vector]: lower bound of the paramters
%
% - **ub** [d x 1 vector]: upper bound of the paramters
%
% - **options** [struct]:
%   - **alpha** [scalar|2-element|{[.25,.45]}]: target acceptance rate
%   - **burnin** [integer|{0}]: number of burn-in initial simulations
%   - **N** [integer|{20000}]: number of simulations
%   - **verbose** [integer|{100}]: displays progress for every multiple of
%   "verbose"
%   - **c** [scalar|{0.25}]: initial scale for the covariance matrix
%   - **c_range** [vector|{}]: range of variation of c
%   - **thin** [integer|{1}]: number of thinning simulations. 1 means we
%   keep every draw, 2 means we keep every second, 3 every third, etc.
%   - **penalty** [numeric|{1e+8}]: worst possible function value
%   - **nchain** [integer|{1}]: number of parallel chains
%   - **rwm_exp** [numeric|{0.6}]: tuning hyper-parameter for scale and
%   covariance matrix
%   - **fixed_scaling** [true|{false}]: if true, the scaling (c) of the
%   covariance matrix is kept constant
%   - **use_true_moments** [true|{false}]: if true, the updated exact
%   covariance matrix of the draws is used at each step. If false, a
%   different update of the covariance matrix is used.
%   - **logproppdf** [function_handle|{[]}]: used when the proposal is not
%   symmetric
%   - **MaxTime** [numeric|{inf}]: maximum simulation time.
%   - **adapt_covariance** [true|{false}]: If true, the covariance matrix
%   is updated with the sampled draws.
%   - **save** [struct|{'every='inf,'location=',pwd,'filename=',''}]:
%   structure with fields "every", "location", "filename"
%   - **recover** [false|{true}]: attempts to recover from an earlier
%   aborted simulation
%   - **recover_start_at_best** [true|{false}]: in an event of a recovery,
%   start all the chains at the best value. Note this will break the chains
%   if the best value is not the last element that was saved in the chain.
%
% - **mu** [d x 1 vector]: initial condition for the sampler
%
% - **SIG** [d x d matrix]: initial covariance matrix
%
% Outputs
% --------
%
% - **Results** [struct]:
%   - **pop** [nchain x N struct]: fields are "x" for the parameter vector
%   and "f" for the value of the parameter vector
%   - **bestf** [numeric]: best function value
%   - **bestx** [vector]: best parameter vector
%   - **best** [nchain x 1]: vector of best individual in each chain
%   - **m** [vector]: mean of the parameter draws
%   - **SIG** [matrix]: covariance of the parameter draws
%   - **m_algo** [vector]: mean with particular updating
%   - **SIG_algo** [matrix]: covariance with particular updating
%   - **funevals** [1 x nchain vector]: function evaluations
%   - **stats** [struct]: stats on the optimization
%
% More About
% ------------
%
% - It is assumed that logf is a function to minimize
%
% Examples
% ---------
%
% See also:	CONSTANT_BVAR_SAMPLER, RRF_SAMPLER

%   - **retune_cov_every** [integer|{100}]: frequence for the retuning of
%   the scale parameter

num_fin=@(x)isnumeric(x) && isscalar(x) && isfinite(x) && isreal(x);

num_fin_int=@(x)num_fin(x) && floor(x)==ceil(x) && x>=0;

savestruct=struct('every',inf,'location',pwd,'filename','');

defaults={ % arg_names -- defaults -- checks -- error_msg
    'alpha',[.25,.45],@(x)((numel(x)==2 && x(2)>=x(1))||numel(x)==1) && all(x>0) && all(x<1),'target_range should be a 2-element vector s.t. x(2)>=x(1) and x(i) in (0,1)'
    'burnin',0,@(x)num_fin_int(x),'burnin should be an integer in [0,inf)'
    'N',20000,@(x)num_fin_int(x) && x>0 ,'N should be a strictly positive integer'
    'verbose',100,@(x)num_fin_int(x) && x>0 ,'verbose should be a strictly positive integer'
    'c',0.25,@(x)all(num_fin(x)) && all(x>0) ,'c (tuning parameter) should be a positive scalar'
    'c_range',[sqrt(eps),100],@(x)numel(x)==2 && all(num_fin(x) & x>0) && x(2)>=x(1),'c_range variation range for tuning parameter must be a two element vector'
    'thin',1,@(x)num_fin_int(x) && x>=1,'thin must be >=1'
    'penalty',1e+8,@(x)isempty(x)||num_fin(x) && x>0,'penalty (worst value possible in absolute value) must be empty or a finite positive number'
    'nchain',1,@(x)num_fin_int(x) && x>0,'nchain(# chains) should be a strictly positive integer'
    'rwm_exp',0.6,@(x)num_fin(x) && x>0.5 && x<1,'rwm_exp (Exponent of random-walk adaptation step size) must be in (1/2,1)'
    'fixed_scaling',false,@(x)isscalar(x) && islogical(x),'fixed_scaling (fixed tuning parameter) should be a logical scalar'
    'use_true_moments',false,@(x)isscalar(x) && islogical(x),'use_true_moments should be a logical scalar'
    'recover',true,@(x)isscalar(x) && islogical(x),'recover should be a logical scalar'
    'recover_start_at_best',false,@(x)isscalar(x) && islogical(x),'recover_start_at_best should be a logical scalar'
    'logproppdf',[],@(x)isa(x,'function_handle'),'logproppdf must be a function handle'
    'MaxTime',inf,@(x)num_fin(x) && x>0,'MaxTime must be a positive scalar'
    'adapt_covariance',false,@(x)isscalar(x) && islogical(x),'adapt_covariance should be a logical scalar'
    'save',savestruct,@(x)isstruct(x) && all(ismember(fieldnames(x),fieldnames(savestruct))),'fields for save must be "every", "location" and "filename"'
%     'delay_rejection',true,@(x)isscalar(x) && islogical(x),'delay_rejection should be a logical scalar'
%     'retune_cov_every',100,@(x)num_fin_int(x) && x>0, 'retune_cov_every should be a positive integer'
    };


if nargin==0
    
    Results=cell2struct(defaults(:,2),defaults(:,1),1);
    
    return
    
end

if nargin<6
    
    SIG_mom=[];
    
    if nargin<5
        
        mu=[];
        
        if nargin<4
            
            options=struct();
            
        end
        
    end
    
end

% number of parameters
[d,ncols]=size(lb);

if ncols~=1
    
    error('number of columns of lb should be 1')
    
end

if ~(all(isfinite(lb)) && all(isfinite(ub)))
    
    error('lb and ub shoud be finite')
    
end

if d==0
    
    error('lb cannot have less than 1 row')
    
end

if ~isequal(size(ub),[d,ncols])
    
    error('size ub does not match size lb')
    
end

options=parse_arguments(defaults,options);

% number of chains
%------------------
nchain=options.nchain;

% burn-in
%--------
burnin=options.burnin;

% tuning parameter for the covariance of the metropolis
%-------------------------------------------------------
log_c=log(options.c)*ones(1,nchain);

c_range=options.c_range;

savefile=options.save.filename;

savelocation=options.save.location;

saveevery=options.save.every;

is_save=isfinite(saveevery);

isave_batch=0;
    
if is_save
    
    if isempty(savelocation)
        
        savelocation=pwd;
        
    end
    
    if isempty(savefile)
        
        savefile='mhDraws';  
        
    end
    
    % try recovering
    %---------------
    
    if options.recover
        
        [~,~,~,summary]=mcmc.process_draws(savelocation);
        
        if summary.nchains
            
            burnin=0;
            
            if nchain~=summary.nchains
               
                error('number of chains does not match')
                
            end
            
            mu=[summary.last.x];
            
            if options.recover_start_at_best
                
                mu=summary.best_of_the_best.x;
                % mu will be expanded below as needed if necessary
                
            end
            
            if ~isempty(summary.last_cov)
                
                SIG_mom=summary.last_cov;
                
            end
            
            if ~isempty(summary.last_cScale)
                
                log_c=log(summary.last_cScale);
                
            end
            
        end
        
        isave_batch=summary.last_saved_index;
        
    end
    
end

if ischar(logf)
    
    logf=str2func(logf);
    
end

logproppdf=options.logproppdf;

symmetric=isempty(logproppdf);

if ~isa(logf,'function_handle')
    
    error('logf should be a function handle or a string')
    
end

% target acceptance range
%------------------------
alpha=options.alpha;

rho=.5*(alpha(1)+alpha(end))*ones(1,nchain);

% more options
%-------------
fixed_scaling=options.fixed_scaling;

rwm_exp=options.rwm_exp;

use_true_moments=options.use_true_moments;

% worst value that the function can assume
%------------------------------------------
penalty=options.penalty;

% thining
%--------
thin=options.thin;

% number of simulations per chain
%----------------------------------
N=options.N;

if isempty(mu)
    
    mu=.5*(ub+lb);
    
end

% covariance adaptations
%-------------------------
adapt_covariance=options.adapt_covariance;

if isempty(SIG_mom)
    
    SIG_mom=utils.mcmc.initial_covariance(lb,ub);
    
    adapt_covariance=true;
    
end

if size(mu,2)<nchain
    
    mu=mu(:,ones(1,nchain));
    
end

if size(SIG_mom,3)<nchain

    SIG_mom=SIG_mom(:,:,ones(1,nchain));
    
end

mu_algo=mu;

SIG_algo=SIG_mom;

% draw initial distribution:
%----------------------------
[stud,funevals,~,~,NumWorkers]=utils.mcmc.initial_draws(logf,lb,ub,nchain,penalty,mu);

% vectorize in case of many parallel chains
stud=stud(:);

% pre-allocate
%--------------
if is_save
    
    saveevery=min(saveevery,N);
    
    pop=stud(:,ones(1,saveevery));
    
    the_iter=0;
    
else
    
    pop=stud(:,ones(1,N));
    
end

d=numel(lb);

obj=struct('funcCount',sum(funevals),'iterations',0,'start_time',clock,...
    'MaxTime',options.MaxTime,'verbose',options.verbose,'MaxFunEvals',inf,...
    'best_fval',[],'MaxNodes',1,'optimizer',mfilename,...
    'number_of_parameters',size(mu,1),'accept_ratio',[]);

sqrt_cSIG=[];

accept_ratio=zeros(1,nchain);

scale_times_sqrt_covariance_updating()

idraw=-burnin;

total_draws=N*thin+burnin;

obj.MaxIter=total_draws;

q_x0_given_y = 0;

q_y_given_x0 = q_x0_given_y;

utils.optim.manual_stopping;

stopflag=utils.optim.check_convergence(obj);

best=stud;

obj.best_fval=[best.f];

% wtbh=waitbar(0,'please wait...','Name','MH sampling');

while isempty(stopflag)
    
    idraw=idraw+1;
    
    obj.iterations=idraw+burnin;
    
    % sample from the proposal distribution
    %---------------------------------------
    y=proprnd();
    
    if ~symmetric
        
        q_x0_given_y = logproppdf(stud,y);
        
        q_y_given_x0 = logproppdf(y,stud);
        
    end
    
    % this is a generic formula.
    rho = ([y.f]+q_x0_given_y)-([stud.f]+q_y_given_x0);
    
    % minimization: change sign: 
    %--------------------------
    rho=-rho;
    
    rho=exp(min(rho,0));
    
    % Accept or reject the proposal
    %-------------------------------
    U=rand(1,nchain);
    
    acc = rho>=U;
    
    stud(acc,:) = y(acc,:); % preserves x's shape.
    
    accept_ratio=((obj.iterations-1)*accept_ratio+acc)/obj.iterations;
    
    % save down
    %----------
    if idraw>0 && mod(idraw,thin)==0 % burnin and thin
        
        if is_save
            
            the_iter=the_iter+1;
            
        else
            
            the_iter=idraw/thin;
            
        end
        
        
        pop(:,the_iter) = stud;
            
        do_save()
        
    end
    
    % update the best
    %-----------------
    tmpf=[stud.f];
    
    good=tmpf<obj.best_fval;
    
    best(good)=stud(good);
    
    obj.best_fval=[best.f];
    
    % update the moments
    %-------------------
    moments_updating()
    
    % update the cCs
    %---------------
    scale_times_sqrt_covariance_updating()
        
    % display progress
    %------------------
    obj.accept_ratio=accept_ratio;
    
    utils.optim.display_progress(obj)
    
    % check convergence
    %------------------
    stopflag=utils.optim.check_convergence(obj);
    
%     waitbar_updating()
end

% delete(wtbh)

Results=do_results();

    function Results=do_results()
        
        if is_save
            % in case we end right at the re-initialization...
           cutoff=max(1,the_iter);
            
        else
            
            cutoff=the_iter;
            
        end
        
        bestOfTheBest=utils.mcmc.sort_population(best);
        
        obj.end_time=clock;
        
        c=exp(log_c); 
        
        Results=struct('pop',pop(:,1:cutoff),...
            'bestf',bestOfTheBest(1).f,...
            'bestx',bestOfTheBest(1).x,...
            'best',best,...
            'm',mu,...
            'SIG',SIG_mom,...
            'thinning',thin,...
            'm_algo',mu_algo,...
            'SIG_algo',SIG_algo,...
            'funevals',funevals,...
            'stats',obj,...
            'c',c);
    end

    function do_save()
        
        if ~(is_save && the_iter==saveevery)
            
            return
            
        end
        
        results=do_results(); %#ok<NASGU>
        
        isave_batch=isave_batch+1;
        
        save(sprintf('%s%s%s_%0.0f',savelocation,filesep,savefile,isave_batch),...
            '-struct','results')
        
        the_iter=0;
        
    end

    function scale_times_sqrt_covariance_updating()
        
            nbatch=obj.iterations;
            
            sqrt_cSIG=SIG_mom;
            
            iterations=obj.iterations;
            
            parfor (ichain=1:nchain,NumWorkers)
                
                if iterations>0
                    
                     log_c(ichain)=utils.mcmc.update_scaling(log_c(ichain),...
                        rho(ichain),alpha,fixed_scaling,nbatch,...
                        rwm_exp,[],c_range);
                    
               end
                
                if use_true_moments
                    
                    sqrt_cSIG(:,:,ichain)=chol(...
                        exp(log_c(ichain))*SIG_mom(:,:,ichain),...
                        'lower');
                    
                else
                    
                    sqrt_cSIG(:,:,ichain)=chol(...
                        exp(log_c(ichain))*SIG_algo(:,:,ichain),...
                        'lower');
                    
                end
                
            end
            
    end

    function moments_updating()
        
        if adapt_covariance
            
            for ichain=1:nchain
                
                [mu(:,ichain),SIG_mom(:,:,ichain)]=utils.moments.recursive(...
                    mu(:,ichain),SIG_mom(:,:,ichain),stud(ichain).x,obj.iterations);
                
                [mu_algo(:,ichain),SIG_algo(:,:,ichain)]=utils.mcmc.update_moments(...
                    mu_algo(:,ichain),SIG_algo(:,:,ichain),stud(ichain).x,obj.iterations,...
                    options.rwm_exp);
                
            end
            
        end
        
    end

    function v1=proprnd()
        
        v1=stud;
        
        parfor (ichain=1:nchain,NumWorkers)
            
            xd=stud(ichain).x+sqrt_cSIG(:,:,ichain)*randn(d,1);
            
            bad=xd<lb; xd(bad)=lb(bad);
            
            bad=xd>ub; xd(bad)=ub(bad);
            
            v1(ichain).x=xd;
            
            v1(ichain).f=logf(xd); %#ok<PFBNS>
            
        end
        
        funevals=funevals+nchain;
        
        obj.funcCount=sum(funevals);
        
    end

%     function waitbar_updating()
%         x=obj.iterations/total_draws;
%         waitbar(x,wtbh,...
%             {
%             sprintf('bestf %s',num2str(obj.best_fval))
%             sprintf('acceptance rate %s',num2str(100*accept_ratio))
%             }...
%             )
%     end

end
