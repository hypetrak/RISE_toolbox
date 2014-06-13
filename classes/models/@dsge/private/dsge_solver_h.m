function [T,eigval,retcode]=dsge_solver_h(obj,structural_matrices)

if isempty(obj)
    if nargout>1
        error([mfilename,':: when the object is emtpy, nargout must be at most 1'])
    end
    T=struct('solve_disable_theta',false); 
    % gather the defaults from fix point iterator and initial guess
    T=utils.miscellaneous.mergestructures(T,fix_point_iterator(),...
        dsge_tools.utils.msre_initial_guess());
    return
end

% It is assumed the steady states have been solved and the derivatives
% evaluated at different orders
%%
Pfunc=@utils.miscellaneous.sum_kroneckers;

%% begin
T=struct();
% options.solve_order 1
%--------
if obj.options.solve_order>=1
    pos=obj.locations.before_solve;
    siz=obj.siz.before_solve;
    % collect the sizes
    %------------------
    siz.h=size(structural_matrices.dv,2);
    siz.nT=siz.ns+siz.np+siz.nb+siz.nf;
    shock_horizon=max(obj.exogenous.shock_horizon);
    siz.nz=siz.np+siz.nb+1+siz.ne*(1+shock_horizon);
    siz.nd=size(structural_matrices.dv{1,1},1); % number of equations
    pos.z.e_plus=pos.z.e_0(end)+(1:shock_horizon*siz.ne);

    % Structure of elements that will move across different orders
    %-------------------------------------------------------------
    others=struct();
    others.theta_hat=structural_matrices.theta_hat;
    
    [T.Tz,others,eigval,retcode]=solve_first_order(structural_matrices.dv,...
        structural_matrices.transition_matrices.Q,others,siz,pos,obj.options,shock_horizon);
    
    % higher orders
    %--------------
    if obj.options.solve_order>=2 && ~retcode
        [T,retcode]=solve_higher_orders(T,others,obj.options.solve_accelerate);
    end
end

    function [T,retcode]=solve_higher_orders(T,others,accelerate)
        % second-order moments
        %---------------------
        Eu_u=sparse(siz.nz^2,siz.nz^2);
        start=siz.nz^2-siz.ne^2;
        % msig=zeros(1,siz.nz);
        % msig(siz.np+siz.nb+1)=1;
        zz_sig_loc=(siz.nz+1)*(siz.np+siz.nb)+1;
        Ie=speye(siz.ne);
        Eu_u(start+1:end,zz_sig_loc)=Ie(:);% Ie(:)*kron(msig,msig)
        clear Ie % msig
        
        a0_z=zeros(siz.nv,siz.nz);
        a0_z(pos.v.b_minus,pos.z.b)=eye(siz.nb);
        a0_z(pos.v.p_minus,pos.z.p)=eye(siz.np);
        a0_z(pos.v.e_0,pos.z.e_0)=eye(siz.ne);
        a1_z=zeros(siz.nv,siz.nz);
        
        hz=zeros(siz.nz);
        hz(pos.z.sig,pos.z.sig)=1;
        hz(siz.np+siz.nb+1+(1:siz.ne*shock_horizon),pos.z.e_plus)=eye(shock_horizon*siz.ne);
        dbf_plus=others.dbf_plus;
        for rt=1:siz.h
            for rplus=1:siz.h
                % this preconditioning could also be done once and for all and
                % should be included in Aplus
                dbf_plus{rt,rplus}=others.Ui(:,:,rt)*dbf_plus{rt,rplus};
            end
        end
        
        Dzz=second_order_rhs();
        [T.Tzz,retcode]=solve_generalized_sylvester(Dzz,2);
        clear Dzz
        
        if obj.options.solve_order>2 && ~retcode
            % store a0, a1 and hz as sparse since we know their non-zero
            % pattern (most likely) will not change.
            a0_z=sparse(a0_z);
            a1_z=sparse(a1_z);
            hz=sparse(hz);
                % third-order moments: no skewed shocks
                %--------------------------------------
                % Eu_u_u=sparse(siz.nz^3,siz.nz^3);
                        
            Dzzz=third_order_rhs();
            [T.Tzzz,retcode]=solve_generalized_sylvester(Dzzz,3);
            clear Dzzz
            
            if obj.options.solve_order>3 && ~retcode
                % fourth-order moments
                %---------------------
                % Eu_u_u_u=sparse(siz.nz^4,siz.nz^4);
                Dzzzz=fourth_order_rhs();
                [T.Tzzzz,retcode]=solve_generalized_sylvester(Dzzzz,4);
                clear Dzzzz
                
                if obj.options.solve_order>4 && ~retcode
                    Dzzzzz=fifth_order_rhs();
                    [T.Tzzzzz,retcode]=solve_generalized_sylvester(Dzzzzz,3);
                    clear Dzzzzz
                    
                    if obj.options.solve_order>5
                        error('perturbations of order greater than 5 not implemented');
                    end
                end
            end
        end
        
        function Dzz=second_order_rhs()
            Dzz=preallocate_rhs(2);
            for r0=1:siz.h
                a0_z(pos.v.t_0,:)=T.Tz{r0};
                hz(pos.z.pb,:)=T.Tz{r0}(pos.t.pb,:);
                for r1=1:siz.h
                    a1_z(pos.v.bf_plus,:)=T.Tz{r1}(pos.t.bf,:);
                    a0_z(pos.v.bf_plus,:)=T.Tz{r1}(pos.t.bf,:)*hz;
                    a0_z(pos.v.theta_plus,pos.z.sig)=others.theta_hat{r0,r1};
                    Evz_vz=kron(a0_z,a0_z)+kron(a1_z,a1_z)*Eu_u;
                    Dzz(:,:,r0)=Dzz(:,:,r0)+structural_matrices.dvv{r0,r1}*Evz_vz;
                end
                % precondition
                Dzz(:,:,r0)=-others.Ui(:,:,r0)*Dzz(:,:,r0);
            end
        end
        
        function Dzzz=third_order_rhs()
            Dzzz=preallocate_rhs(3);
            a0_zz=zeros(siz.nv,siz.nz^2);
            a1_zz=zeros(siz.nv,siz.nz^2);
            hzz=zeros(siz.nz,siz.nz^2);
            for r0=1:siz.h
                a0_z(pos.v.t_0,:)=T.Tz{r0};
                a0_zz(pos.v.t_0,:)=T.Tzz{r0};
                hz(pos.z.pb,:)=T.Tz{r0}(pos.t.pb,:);
                hzz(pos.z.pb,:)=T.Tzz{r0}(pos.t.pb,:);
                for r1=1:siz.h
                    a1_z(pos.v.bf_plus,:)=T.Tz{r1}(pos.t.bf,:);
                    a0_z(pos.v.bf_plus,:)=T.Tz{r1}(pos.t.bf,:)*hz;
                    a0_z(pos.v.theta_plus,pos.z.sig)=others.theta_hat{r0,r1};
                    
                    a0_zz(pos.v.bf_plus,:)=T.Tz{r1}(pos.t.bf,:)*hzz+T.Tzz{r1}(pos.t.bf,:)*kron(hz,hz);
                    a1_zz(pos.v.bf_plus,:)=T.Tzz{r1}(pos.t.bf,:);

                    Dzzz(:,:,r0)=Dzzz(:,:,r0)+...
                        dvvv_Evz_vz_vz()+...
                        dvv_Evz_vzz()+...
                        others.dbf_plus{rt,rplus}*Tzz_hz_hzz();
                end
                % precondition
                Dzzz(:,:,r0)=-others.Ui(:,:,r0)*Dzzz(:,:,r0);
            end
            
            function res=dvv_Evz_vzz()
                % res=d.dvv{r0,r1}*Evz_vzz();
                res=omega_1(structural_matrices.dvv{r0,r1},a0_z,a0_zz+a1_zz*Eu_u)+...
                    0; % unfinished
            end
            
            function res=Tzz_hz_hzz()
                res=omega_1(T.Tzz{r1}(pos.t.bf,:),hz,hzz);
            end
            
            function res=dvvv_Evz_vz_vz()
                res=structural_matrices.dvvv{r0,r1}*(kron(kron(a0_z,a0_z),a0_z)+...
                    kron(a0_z,kron(a1_z,a1_z)*Eu_u)+...
                    kron(kron(a1_z,a1_z)*Eu_u,a0_z)+...
                    0); % unfinished
            end
            
            function res=omega_1(dvv,vz,vzz)
                res=utils.kronecker.A_times_B_kron_C(dvv,vz,vzz);
                res=res+utils.kronecker.A_times_B_kron_C(dvv,vzz,vz);
                nz=siz.nz;
                for ipage=1:nz
                    point=(ipage-1)*nz+1:ipage*nz;
                    cols=(ipage-1)*nz^2+1:ipage*nz^2;
                    res(:,cols)=res(:,cols)+utils.kronecker.A_times_B_kron_C(dvv,vzz(:,point),vz);
                end
            end
        end
        
        function D=preallocate_rhs(oo)
            D=zeros(siz.nd,siz.nz^oo,siz.h);
        end
        
        function [X,retcode]=solve_generalized_sylvester(D,oo)
            [X,retcode] = tfqmr(@afun,D(:),obj.options.fix_point_TolFun);
            if retcode
                %     0 tfqmr converged to the desired tolerance TOL within MAXIT iterations.
                %     1 tfqmr iterated MAXIT times but did not converge.
                %     2 preconditioner M was ill-conditioned.
                %     3 tfqmr stagnated (two consecutive iterates were the same).
                %     4 one of the scalar quantities calculated during tfqmr became too
            else
                X=reshape(X,[siz.nd,siz.nz^oo,siz.h]);
                tmp=cell(1,siz.h);
                for r0=1:siz.h
                    tmp{r0}=X(:,:,r0);
                end
                X=tmp;
            end
            
            function AT=afun(tau)
                tau=reshape(tau,[siz.nd,siz.nz^oo,siz.h]);
                AT=zeros(size(tau));
                for r00=1:siz.h
                    hz(pos.z.pb,:)=T.Tz{r00}(pos.t.pb,:);
                    AT_0=0;
                    for r1=1:siz.h
                        AT_0=AT_0+dbf_plus{r00,r1}*tau(pos.t.bf,:,r1);
                    end
                    switch oo
                        case 2
                            tmp_u=Eu_u;
                        case 3
                            no_skewed_shocks=0;
                            tmp_u=no_skewed_shocks+Pfunc(hz,Eu_u);
                        otherwise
                            error(['approximation of order ',int2str(oo),' not yet implemented'])
                    end
                    tmp_u=sparse(AT_0*tmp_u);
                    % use the fast kronecker only where it is really needed
                    %------------------------------------------------------
                    AT_0=utils.kronecker.X_times_kron_Q1_Qk(AT_0(:),{transpose(hz),oo},{speye(siz.nd),1});
                    AT(:,:,r00)=reshape(AT_0,[siz.nd,siz.nz^oo])+tmp_u+tau(:,:,r00);
                end
                AT=AT(:);
            end
        end
    end

end

function [Tz,others,eigval,retcode]=solve_first_order(dv,Q,others,siz,pos,options,k_future)

[dbf_plus,ds_0,dp_0,db_0,df_0,dpb_minus]=utils.solve.pull_first_order_partitions(dv,pos.v);

[Tz_pb,eigval,retcode]=dsge_solver_first_order_autoregress_h(dbf_plus,ds_0,dp_0,db_0,df_0,dpb_minus,Q,siz,pos,options);

Tz=cell(1,siz.h);
if ~retcode
% (non-)certainty equivalence
%----------------------------
dt_t=zeros(siz.nd,siz.h);
A0sig=zeros(siz.nd,siz.nT,siz.h);
A0=zeros(siz.nd,siz.nT,siz.h);
Tz_sig=zeros(siz.nT,siz.h);
df_Lf_Tzp_Lp=zeros(siz.nd,siz.nT);
db_Lb_Tzb_Lb=zeros(siz.nd,siz.nT);
UUi=zeros(siz.nd,siz.nT,siz.h);
others.dbf_plus=cell(siz.h);
for rt=1:siz.h
    de_0_rt=0;
    Sdbf_plus_rt=0;
    for rplus=1:siz.h
        ds_0=dv{rt,rplus}(:,pos.v.s_0);
        dp_0=dv{rt,rplus}(:,pos.v.p_0);
        db_0=dv{rt,rplus}(:,pos.v.b_0);
        df_0=dv{rt,rplus}(:,pos.v.f_0);
        A0_0_1=[ds_0,dp_0,db_0,df_0];
        A0(:,:,rt)=A0(:,:,rt)+A0_0_1;
        % provision for non-certainty equivalence
        %----------------------------------------
        dtheta_plus=dv{rt,rplus}(:,pos.v.theta_plus);
        df_plus=dv{rt,rplus}(:,pos.v.f_plus);
        db_plus=dv{rt,rplus}(:,pos.v.b_plus);
        df_Lf_Tzp_Lp(:,pos.t.p)=df_plus*Tz_pb(pos.t.f,1:siz.np,rplus);% place in the p position
        db_Lb_Tzb_Lb(:,pos.t.b)=db_plus*Tz_pb(pos.t.b,siz.np+(1:siz.nb),rplus);% place in the b position
        A0sig(:,:,rt) = A0sig(:,:,rt) + A0_0_1 + df_Lf_Tzp_Lp + db_Lb_Tzb_Lb;
        dt_t(:,rt)=dt_t(:,rt)+dtheta_plus*others.theta_hat{rt,rplus};
        
        % provision for shock impacts
        %----------------------------
        de_0=dv{rt,rplus}(:,pos.v.e_0);
        others.dbf_plus{rt,rplus}=dv{rt,rplus}(:,pos.v.bf_plus);
        UUi(:,:,rt)=UUi(:,:,rt)+A0_0_1;
        UUi(:,pos.t.pb,rt)=UUi(:,pos.t.pb,rt)+others.dbf_plus{rt,rplus}*Tz_pb(pos.t.bf,:,rplus);
        de_0_rt=de_0_rt+de_0;
        if k_future
            Sdbf_plus_rt=Sdbf_plus_rt+others.dbf_plus{rt,rplus};
        end
    end
    % shock impacts (current)
    %------------------------
    UUi(:,:,rt)=UUi(:,:,rt)\eye(siz.nT);
    Tz_e_rt=-UUi(:,:,rt)*de_0_rt;
    % shock impacts (future)
    %-----------------------
    for ik=1:k_future
        Tz_e_rt(:,:,ik+1)=-UUi(:,:,rt)*Sdbf_plus_rt*Tz_e_rt(pos.t.bf,:,ik);
    end
    Tz_e_rt=reshape(Tz_e_rt,siz.nd,siz.ne*(k_future+1));
    Tz{rt}=[Tz_pb(:,:,rt),Tz_sig(:,rt),Tz_e_rt];
end

% now solve sum(A+*Tz_sig(+)+A0_sig*Tz_sig+dt_t=0
%-------------------------------------------------
Tz_sig=solve_perturbation_impact(Tz_sig,A0sig,others.dbf_plus,dt_t);
if any(Tz_sig(:))
    for rt=1:siz.h
        Tz{rt}(:,siz.np+siz.nb+1)=Tz_sig(:,rt);
    end
end
others.Ui=UUi;
end

    function Tz_sig=solve_perturbation_impact(Tz_sig,A0sig,dbf_plus,dt_t)
        if any(dt_t(:))% then automatically h>1
            % use a qr decomposition to solve a small system. Given the structure
            % of the system, it is enough to precondition it.
            %-----------------------------------------------
            for r0=1:siz.h
                A0_sig_i=A0sig(:,:,r0)\eye(siz.nd);
                for r1=1:siz.h
                    dbf_plus{r0,r1}=A0_sig_i*dbf_plus{r0,r1};
                end
                dt_t(:,r0)=A0_sig_i*dt_t(:,r0);
            end
            % now we solve the system sum(A+*Tz_sig(+)+Tz_sig+dt_t=0 first for
            % variables p,b,f and then for variables s
            clear A0sig
            
            % solve the small system without static variables
            %------------------------------------------------
            % the direct solution implemented below is not efficient in very large
            % systems...
            npbf=siz.np+siz.nb+siz.nf;
            A=zeros(npbf*siz.h);
            for r0=1:siz.h
                row_=(r0-1)*npbf+1:r0*npbf;
                for r1=1:siz.h
                    col_=(r1-1)*npbf+1:r1*npbf;
                    A(row_,col_)=[zeros(npbf,siz.np),dbf_plus{r0,r1}(siz.ns+1:end,:)];
                    if r0==r1
                        A(row_,col_)=A(row_,col_)+eye(npbf);
                    end
                end
            end
            Tz_sig_PBF=uminus(dt_t(siz.ns+1:end,:));
            Tz_sig_PBF=A\Tz_sig_PBF(:);
            Tz_sig(siz.ns+1:end,:)=reshape(Tz_sig_PBF,npbf,siz.h);
            
            % solve the static variables
            %---------------------------
            for r0=1:siz.h
                Tz_sig(1:siz.ns,r0)=dt_t(1:siz.ns,r0);
                for r1=1:siz.h
                    Tz_sig(1:siz.ns,r0)=Tz_sig(1:siz.ns,r0)+...
                        dbf_plus{r0,r1}(1:siz.ns,:)*Tz_sig(pos.t.bf,r1);
                end
                Tz_sig(1:siz.ns,r0)=uminus(Tz_sig(1:siz.ns,r0));
            end
        end
    end
end

function [Tz_pb,eigval,retcode]=dsge_solver_first_order_autoregress_1(dbf_plus,ds_0,dp_0,db_0,df_0,dpb_minus,siz,options)
rise_qz_criterium=sqrt(eps);
switch options.solver
    case 1
        [Tz_pb,eigval,retcode]=rise_solve_constant();
    case 2
        [Tz_pb,eigval,retcode]=klein_solve();
    case 22
        [Tz_pb,eigval,retcode]=aim_solve();
    case 23
        [Tz_pb,eigval,retcode]=sims_solve();
    otherwise
        % user-defined solver
        %--------------------
        Aplus=[zeros(siz.nd,siz.ns+siz.np),dbf_plus{1,1}];
        A0=[ds_0{1,1},dp_0{1,1},db_0{1,1},df_0{1,1}];
        Aminus=[zeros(siz.nd,siz.ns),dpb_minus{1,1},zeros(siz.nd,siz.nf)];
        [Tz_pb,eigval,retcode]=options.solver(Aplus,A0,Aminus);
        Tz_pb=Tz_pb(:,siz.ns+(1:siz.np+siz.nb));
        % error(['solver ',parser.any2str(options.solver),' not implemented'])
end

    function [Tz_pb,eigval,retcode]=aim_solve(varargin)
        error('the aim solver is not yet implemented')
    end

    function [Tz_pb,eigval,retcode]=sims_solve(varargin)
        error('the sims solver is not yet implemented')
    end

    function [TT,SS,Z,eigval,retcode]=process_eigenvalues(TT,SS,Q,Z,npred)
            % Ordered inverse eigenvalues
            %----------------------------
            eigval = ordeig(TT,SS);
            stable = abs(eigval) >= 1 + rise_qz_criterium;
            nstable = sum(stable);
            unit = abs(abs(eigval)-1) < rise_qz_criterium;
            nunit = sum(unit);
            
            retcode=0;
            if nstable+nunit<npred
                retcode=22; % no solution
            elseif nstable+nunit>npred
                retcode=21; % multiple solutions
            else
                % Clusters of unit, stable, and unstable eigenvalues.
                clusters = zeros(size(eigval));
                
                % Unit roots first.
                %------------------
                clusters(unit) = 2;
                
                % Stable roots second.
                %---------------------
                clusters(stable) = 1;
                
                % Unstable roots last.
                %---------------------
                
                % Re-order by the clusters.
                %--------------------------
                [TT,SS,~,Z] = ordqz(TT,SS,Q,Z,clusters);
            end
            % Undo the eigval inversion.
            %---------------------------
            infeigval = eigval == 0;
            eigval(~infeigval) = 1./eigval(~infeigval);
            eigval(infeigval) = Inf;
    end

    function [Tz_pb,eigval,retcode]=klein_solve()
        % put system in the form a*x(t+1)=b*x(t) where x=[x0,xf];
        %--------------------------------------------------------
        nbf=siz.nb+siz.nf;
        bf_loc=siz.ns+siz.np+(1:siz.nb+siz.nf);
        pb_loc=siz.ns+(1:siz.np+siz.nb);
            B0=[ds_0{1,1},dp_0{1,1},db_0{1,1},df_0{1,1}];
            Bminus=[zeros(siz.nd,siz.ns),dpb_minus{1,1},zeros(siz.nd,siz.nf)];
        
        a=[B0,dbf_plus{1,1}
            zeros(nbf,siz.nd+nbf)];
        a(siz.nd+1:end,bf_loc)=eye(nbf);
        
        b=[Bminus,zeros(siz.nd,nbf)
            zeros(nbf,siz.nd),-eye(nbf)];
        b=-b;
        
        [Tz_pb,eigval,retcode] = solab(siz.nd);
        if ~retcode
            Tz_pb=Tz_pb(:,pb_loc);
        end
        
        function [sol,eigval,retcode] = solab(npred)
            % npred = number of stable guys
            [TT,SS,Q,Z] = qz(full(a),full(b));      % upper triangular factorization of the matrix pencil b-za
            
            % process eigenvalues
            %---------------------
            [TT,SS,Z,eigval,retcode]=process_eigenvalues(TT,SS,Q,Z,npred);
            
            sol=[];
            if ~retcode                
                z11 = Z(1:npred,1:npred);
                
                z11i = z11\eye(npred);
                s11 = TT(1:npred,1:npred);
                t11 = SS(1:npred,1:npred);
                
                dyn = s11\t11;
                sol = real(z11*dyn*z11i);
                % z21 = Z(npred+1:end,1:npred);
                % f = real(z21*z11i); % already included in the lower part of p
            end
        end
    end

    function [Tzp,eigval,retcode]=rise_solve_constant()
        % state variables (lags): pred,both
        %----------------------------------
        Apb_minus=[dpb_minus{1,1}
            sparse(siz.nb,siz.nb+siz.np)]; % auxiliary equations for 'both' variables
        
        % forward-looking variables (leads): static,both,forward
        %-------------------------------------------------------
        Asbf_plus=[sparse(siz.nd,siz.ns),dbf_plus{1,1}
            sparse(siz.nb,siz.nb+siz.nf+siz.ns)]; % auxiliary equations for 'both' variables
        
        % forward-looking variables (current): static,both,forward
        %---------------------------------------------------------
        Asbf_0=[ds_0{1,1},sparse(siz.nd,siz.nb),df_0{1,1}
            sparse(siz.nb,siz.ns),speye(siz.nb),sparse(siz.nb,siz.nf)]; % auxiliary equations for 'both' variables
        
        % state variables (current): pred,both
        %-------------------------------------
        Apb_0=[dp_0{1,1},db_0{1,1}
            sparse(siz.nb,siz.np),-speye(siz.nb)]; % auxiliary equations for 'both' variables
        [Tzp,eigval,retcode]=rise_solve_1(Asbf_plus,Apb_0,Asbf_0,Apb_minus);
        if ~retcode
            % Re-order [s,b,f,p,b] as [s,p,b,f].we simply can ignore the last b
            %------------------------------------------------------------------
            static_=1:siz.ns;
            pred_=siz.ns+siz.nb+siz.nf+(1:siz.np);
            both_=siz.ns+(1:siz.nb);
            frwrd_=siz.ns+siz.nb+(1:siz.nf);
            order_var=[static_,pred_,both_,frwrd_];
            Tzp=Tzp(order_var,:);
        end
        function [Tzp,eigval,retcode]=rise_solve_1(Afrwrd_plus,Apred_0,Afrwrd_0,Apred_minus)
            A=[Apred_0,Afrwrd_plus]; % pred,frwrd
            B=-[Apred_minus,Afrwrd_0]; % pred,frwrd
            npred=size(Apred_0,2);
            nfrwrd=size(Afrwrd_0,2);
            % real schur decomposition
            %-------------------------
            [TT,SS,Q,Z] = qz(full(A),full(B),'real');
            % so we have Q*A*Z = TT, Q*B*Z = SS.
            
            % process eigenvalues
            %---------------------
            [TT,SS,Z,eigval,retcode]=process_eigenvalues(TT,SS,Q,Z,npred);
            
            Tzp=[];
            if ~retcode
                % define
                %-------
                W=Z.';
                % partition matrices
                %-------------------
                pred=1:npred;
                frwrd=npred+(1:nfrwrd);
                W11=W(pred,pred);
                W12=W(pred,frwrd);
                W21=W(frwrd,pred);
                W22=W(frwrd,frwrd);
                
                S11=SS(pred,pred); % S12=SS(pred,frwrd); % S21=SS(frwrd,pred); % S22=SS(frwrd,frwrd);
                
                T11=TT(pred,pred); % T12=TT(pred,frwrd); % T21=TT(frwrd,pred); % T22=TT(frwrd,frwrd);
                
                % form solution: forward-looking variables
                %-----------------------------------------
                Fzp=-W22\W21;
                tmp=W11+W12*Fzp;
                
                % form solution: predetermined variables
                %---------------------------------------
                Pzp=(T11*tmp)\S11*tmp;
                
                % final solution matrix: Forward-looking+predetermined
                %-----------------------------------------------------
                Tzp=[Fzp;Pzp];
            end
        end
    end
end

function [Tz_pb,eigval,retcode]=dsge_solver_first_order_autoregress_h(dbf_plus,ds_0,dp_0,db_0,df_0,dpb_minus,Q,siz,pos,options)

% options
%--------


bf_cols_adjusted=pos.t.bf;
pb_cols_adjusted=pos.t.pb;

nd_adjusted=siz.nd;
siz_adjusted=siz;
accelerate=options.solve_accelerate && siz.ns;
if accelerate
    Abar_minus_s=cell(1,siz.h);
    R_s_s=cell(1,siz.h);
    R_s_ns=cell(1,siz.h);
    Abar_plus_s=cell(siz.h);
    nd_adjusted=nd_adjusted-siz.ns;
    bf_cols_adjusted=bf_cols_adjusted-siz.ns;
    pb_cols_adjusted=pb_cols_adjusted-siz.ns;
    siz_adjusted.ns=0;
    siz_adjusted.nd=siz_adjusted.nd-siz.ns;
    siz_adjusted.nT=siz_adjusted.nT-siz.ns;
end
% aggregate A0 and A_
%--------------------
d0=num2cell(zeros(1,siz.h));
d_=num2cell(zeros(1,siz.h));
for r0=1:siz.h
    for r1=1:siz.h
        d0{r0}=d0{r0}+[ds_0{r0,r1},dp_0{r0,r1},db_0{r0,r1},df_0{r0,r1}];
        d_{r0}=d_{r0}+dpb_minus{r0,r1};
    end
    % eliminate static variables for speed
    %-------------------------------------
    if accelerate
        [Q0,d0{r0}]=qr(d0{r0});
        d_{r0}=Q0'*d_{r0};
        Abar_minus_s{r0}=d_{r0}(1:siz.ns,:);
        d_{r0}=d_{r0}(siz.ns+1:end,:);
        for r1=1:siz.h
            dbf_plus{r0,r1}=Q0'*dbf_plus{r0,r1};
            Abar_plus_s{r0,r1}=dbf_plus{r0,r1}(1:siz.ns,:);
            dbf_plus{r0,r1}=dbf_plus{r0,r1}(siz.ns+1:end,:);
        end
        R_s_s{r0}=d0{r0}(1:siz.ns,1:siz.ns);
        R_s_ns{r0}=d0{r0}(1:siz.ns,siz.ns+1:end);
        d0{r0}=d0{r0}(siz.ns+1:end,siz.ns+1:end);
    end
end
dpb_minus=d_; clear d_

if isempty(options.solver)
    if is_eigenvalue_solver()
        options.solver=1;
    else
        options.solver=3;
    end
end

kron_method=options.solver==4;

if options.solver==3
    iterate_func=@(x)functional_iteration_h(x,dbf_plus,d0,dpb_minus,bf_cols_adjusted,pb_cols_adjusted);
elseif options.solver>3
    iterate_func=@(x)newton_iteration_h(x,dbf_plus,d0,dpb_minus,bf_cols_adjusted,pb_cols_adjusted,kron_method);
end
eigval=[];

T0=dsge_tools.utils.msre_initial_guess(d0,dpb_minus,dbf_plus,options.solve_initialization);

switch options.solver
    case {1,2}
        [Tz_pb,eigval,retcode]=dsge_solver_first_order_autoregress_1(dbf_plus,ds_0,dp_0,db_0,df_0,dpb_minus,siz_adjusted,options);
    case {3,4,5}
        % T00=evalin('base','T00');
        [Tz_pb,~,retcode]=fix_point_iterator(iterate_func,T0,options);
    otherwise
        % user-defined solver
        %--------------------
        Aplus=zeros(siz_adjusted.nd,siz_adjusted.nd,siz_adjusted.h,siz_adjusted.h);
        A0=zeros(siz_adjusted.nd,siz_adjusted.nd,siz_adjusted.h);
        Aminus=zeros(siz_adjusted.nd,siz_adjusted.nd,siz_adjusted.h);
        for r0=1:siz_adjusted.h
            A0(:,:,r0)=d0{r0};
            Aminus(:,siz_adjusted.ns+(1:siz_adjusted.np+siz_adjusted.nb),r0)=dpb_minus{r0};
            for r1=1:siz_adjusted.h
                Aplus(:,siz_adjusted.ns+siz_adjusted.np+(1:siz_adjusted.nb+siz_adjusted.nf),r0,r1)=dbf_plus{r0,r1};
            end
        end
        [Tz_pb,~,retcode]=options.solver(Aplus,A0,Aminus);
        Tz_pb=Tz_pb(:,siz_adjusted.ns+(1:siz_adjusted.np+siz_adjusted.nb));
        % error(['undefined solver :: ',parser.any2str(options.solver)])
end

if ~retcode
    npb=siz.np+siz.nb;
    Tz_pb=reshape(Tz_pb,[nd_adjusted,npb,siz.h]);
    if accelerate
        % solve for the static variables
        %-------------------------------
        Sz_pb=zeros(siz.ns,npb,siz.h);
        for r0=1:siz.h
            ATT=0;
            for r1=1:siz.h
                ATT=ATT+Abar_plus_s{r0,r1}*Tz_pb(siz.np+1:end,:,r1); % <-- Tz_pb(npb+1:end,:,r1); we need also the both variables
            end
            ATT=ATT*Tz_pb(1:npb,:,r0);
            Sz_pb(:,:,r0)=-R_s_s{r0}\(Abar_minus_s{r0}+R_s_ns{r0}*Tz_pb(:,:,r0)+ATT);
        end
        Tz_pb=cat(1,Sz_pb,Tz_pb);
    end
end

    function flag=is_eigenvalue_solver()
        flag=true;
        if ~(siz.h==1||all(diag(Q)==1))
            d0_test=d0{1};
            dpb_minus_test=dpb_minus{1};
            dbf_plus0=reconfigure_aplus();
            dbf_plus_test=dbf_plus0{1};
            % check whether it is shocks only
            for st=2:siz.h
                t0=get_max(d0_test-d0{st});
                tplus=get_max(dbf_plus_test-dbf_plus0{st});
                tminus=get_max(dpb_minus_test-dpb_minus{st});
                tmax=max([t0,tplus,tminus]);
                if tmax>1e-9
                    flag=false;
                    break
                end
            end
        end
        function Apl=reconfigure_aplus()
            Apl=cell(siz.h,1);
            for ii=1:siz.h
                Apl{ii}=dbf_plus{ii,ii}/Q(ii,ii);
            end
        end
        function m=get_max(x)
            m=max(abs(x(:)));
        end
    end

end

function [T1,T0_T1]=functional_iteration_h(T0,dbf_plus,d0,dpb_minus,bf_cols,pb_cols,~)
n=size(d0{1},1);
h=size(d0,2);
if nargin<6
    pb_cols=[];
    if nargin<5
        bf_cols=[];
    end
end
if isempty(bf_cols)
    bf_cols=1:n;
end
if isempty(pb_cols)
    pb_cols=1:n;
end
npb=numel(pb_cols);
if size(dbf_plus{1},2)~=numel(bf_cols)
    error('number of columns of dbf_plus inconsistent with the number of bf variables')
end
if size(dpb_minus{1},2)~=npb
    error('number of columns of dpb_minus inconsistent with the number of bp variables')
end

T0=reshape(T0,[n,npb,h]);
T1=T0;
for r0=1:h
    U=d0{r0};
    for r1=1:h
        U(:,pb_cols)=U(:,pb_cols)+dbf_plus{r0,r1}*T0(bf_cols,:,r1);
    end
    T1(:,:,r0)=-U\dpb_minus{r0};
end
% update T
%---------
T1=reshape(T1,[n,npb*h]);

T0_T1=reshape(T0,[n,npb*h])-T1;

end

function [T1,W1]=newton_iteration_h(T0,dbf_plus,d0,dpb_minus,bf_cols,pb_cols,kron_method)

n=size(d0{1},1);
h=size(d0,2);
if nargin<7
    kron_method=[];
    if nargin<6
        pb_cols=[];
        if nargin<5
            bf_cols=[];
        end
    end
end

if isempty(kron_method)
    kron_method=true;
end
if isempty(bf_cols)
    bf_cols=1:n;
end
if isempty(pb_cols)
    pb_cols=1:n;
end
npb=numel(pb_cols);
if size(dbf_plus{1},2)~=numel(bf_cols)
    error('number of columns of dbf_plus inconsistent with the number of bf variables')
end
if size(dpb_minus{1},2)~=npb
    error('number of columns of dpb_minus inconsistent with the number of bp variables')
end

if isempty(T0)
    T0=zeros(n,npb,h);
end

n_npb=n*npb;
T0=reshape(T0,[n,npb,h]);
W=T0;
if kron_method
    G=zeros(n_npb*h);
else
    LMINUS=cell(1,h);
    LPLUS=cell(h);
end
% Lminus=zeros(npb);
Lplus01=zeros(n);
I_nx_nd=speye(n_npb);
for r0=1:h
    U=d0{r0};
    for r1=1:h
        U(:,pb_cols)=U(:,pb_cols)+dbf_plus{r0,r1}*T0(bf_cols,:,r1);
    end
    Ui=U\speye(n);
    T1_fi=-Ui*dpb_minus{r0};
    W(:,:,r0)=W(:,:,r0)-T1_fi;
    
    Lminus=-T1_fi(pb_cols,:);
    if kron_method
        Lminus_prime=Lminus.';
    else
        LMINUS{r0}=sparse(Lminus);
    end
    rows=(r0-1)*n_npb+1:r0*n_npb;
    for r1=1:h
        cols=(r1-1)*n_npb+1:r1*n_npb;
        Lplus01(:,bf_cols)=Ui*dbf_plus{r0,r1};
        if kron_method
            % build G
            %--------
            tmp=kron(Lminus_prime,Lplus01);
            if r0==r1
                tmp=tmp-I_nx_nd;
            end
            G(rows,cols)=tmp;
        else
            LPLUS{r0,r1}=sparse(Lplus01);
        end
    end
end
W=reshape(W,[n,npb*h]);
if kron_method
    % update T
    %---------
    delta=G\W(:);
else
    tol=sqrt(eps);
    delta=tfqmr(@(x)find_newton_step(x,LPLUS,LMINUS),-W(:),tol);
end

T1=T0+reshape(delta,[n,npb,h]);
if nargout>1
    W1=update_criterion();
end
T1=reshape(T1,[n,npb*h]);

    function W1=update_criterion()
        W1=T1;
        for r00=1:h
            U=d0{r00};
            for r11=1:h
                U(:,pb_cols)=U(:,pb_cols)+dbf_plus{r00,r11}*T1(bf_cols,:,r11);
            end
            Ui=U\eye(n);
            T1_fi=-Ui*dpb_minus{r00};
            W1(:,:,r00)=W1(:,:,r00)-T1_fi;
        end
    end

    function Gd=find_newton_step(delta,Lplus,Lminus)
        Gd=zeros(n*npb,h); % G*delta
        delta=reshape(delta,[n*npb,h]);
        for r00=1:h
            for r11=1:h
                Gd(:,r00)=Gd(:,r00)+vec(Lplus{r00,r11}*reshape(delta(:,r11),n,npb)*Lminus{r00});
            end
        end
        Gd=delta-Gd;
        Gd=Gd(:);
    end
    function x=vec(x)
        x=x(:);
    end
end


%             function res=hz_hzz()
%                 %res=kron(hz,hzz); res=omega_1(res);
%                 res=kron(hz,hzz)+kron(hzz,hz);
%                 tmp=reshape(hzz,[siz.nz,siz.nz,siz.nz]);
%                 tmp2=zeros(siz.nz^2,siz.nz^2,siz.nz);
%                 for ipage=1:siz.nz
%                     tmp2(:,:,ipage)=kron(hz,tmp(:,:,ipage));
%                 end
%                 res=res+reshape(tmp2,[siz.nz^2,siz.nz^3]);
%             end