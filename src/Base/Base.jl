using LinearAlgebra,FileIO,Distributions,DataFrames,StatsBase,GLM,LsqFit,HypothesisTests,Colors,Images,ImageFiltering,SpecialFunctions,
DSP,HCubature,Combinatorics,DataStructures,ANOVA,StatsFuns,Trapz

include("NeuroDataType.jl")
include("CircStats.jl")
include("Spike.jl")
include("LFP.jl")
include("Image.jl")
include("2P.jl")

anscombe(x) = 2*sqrt(x+(3/8))

"Check if `response` is significently different from `baseline` by `Wilcoxon Signed Rank Test`"
isresponsive(baseline,response;alpha=0.05) = pvalue(SignedRankTest(baseline,response)) < alpha
"Check if any `sub group of response` is significently different from `baseline` by `Wilcoxon Signed Rank Test`"
isresponsive(baseline,response,gi;alpha=0.05) = any(map(i->isresponsive(baseline[i],response[i],alpha=alpha),gi))
isresponsive(baseline::Vector,response::Matrix;alpha=0.05) = any(isresponsive.(baseline,response,alpha=alpha))

"Check if any factors and their interactions significently modulate response by ANOVA"
function ismodulative(df;alpha=0.05,interact=true)
    xns = filter(i->i!=:Y,names(df))
    categorical!(df,xns)
    if interact
        f = Term(:Y) ~ reduce(+,map(i->reduce(&,term.(i)),combinations(xns)))
    else
        f = Term(:Y) ~ reduce(+,term.(xns))
    end
    lmr = fit(LinearModel,f,df,contrasts = Dict(x=>EffectsCoding() for x in xns))
    anovatype = length(xns) <= 1 ? 2 : 3
    any(Anova(lmr,anovatype = anovatype).p[1:end-1] .< alpha)
end

"`Gaussian` function"
gaussianf(x;a=1,μ=0,σ=1) = a*exp(-0.5((x-μ)/σ)^2)
function gaussianf(x,y;a=1,μ₁=0,σ₁=1,μ₂=0,σ₂=1,θ=0)
    sinv,cosv = sincos(θ)
    x′ = cosv * x + sinv * y
    y′ = cosv * y - sinv * x
    a*exp(-0.5(((x′-μ₁)/σ₁)^2 + ((y′-μ₂)/σ₂)^2))
end

"""
`von Mises` function [^1]

```math
f(α) =  βe^{κ(cos(n(α - μ)) - 1)}
```

[^1]

Swindale, N.V. (1998). Orientation tuning curves: empirical description and estimation of parameters. Biol Cybern 78, 45–56.

- β: amplitude at μ
- μ: angle of peak
- κ: width parameter
- n: frequency parameter
"""
vmf(α,β=1,μ=0,κ=1;n=1) = β*exp(κ*(cos(n*(α-μ))-1))
"""
`Generalized von Mises` function [^1]

```math
f(α) =  βe^{κ₁(cos(α - μ₁) - 1) + κ₂(cos2(α - μ₂) - 1)}
```

[^1]

Gatto, R., and Jammalamadaka, S.R. (2007). The generalized von Mises distribution. Statistical Methodology 4, 341–353.
"""
gvmf(α,β=1,μ₁=0,κ₁=1,μ₂=0,κ₂=1) = β*exp(κ₁*(cos(α-μ₁)-1) + κ₂*(cos(2(α-μ₂))-1))

"""
`Difference of Gaussians` function
"""
dogf(x;aₑ=2,μₑ=0,σₑ=1,aᵢ=1,μᵢ=0,σᵢ=2) = gaussianf(x,a=aₑ,μ=μₑ,σ=σₑ) - gaussianf(x,a=aᵢ,μ=μᵢ,σ=σᵢ)
function dogf(x,y;aₑ=2,μₑ₁=0,σₑ₁=1,μₑ₂=0,σₑ₂=1,θₑ=0,aᵢ=1,μᵢ₁=0,σᵢ₁=2,μᵢ₂=0,σᵢ₂=2,θᵢ=0)
    sinvₑ,cosvₑ = sincos(θₑ)
    xₑ′ = cosvₑ * x + sinvₑ * y
    yₑ′ = cosvₑ * y - sinvₑ * x
    sinvᵢ,cosvᵢ = sincos(θᵢ)
    xᵢ′ = cosvᵢ * x + sinvᵢ * y
    yᵢ′ = cosvᵢ * y - sinvᵢ * x
    aₑ*exp(-0.5(((xₑ′-μₑ₁)/σₑ₁)^2 + ((yₑ′-μₑ₂)/σₑ₂)^2)) - aᵢ*exp(-0.5(((xᵢ′-μᵢ₁)/σᵢ₁)^2 + ((yᵢ′-μᵢ₂)/σᵢ₂)^2))
end

"Plane sin wave funtion"
function gratingf(x,y;θ=0,f=1,phase=0)
    sinv,cosv = sincos(θ)
    y′ = cosv * y - sinv * x
    sin(2π*(f * y′ + phase))
end

"`Gabor` function"
gaborf(x;a=1,μ=0,σ=1,f=1,phase=0) = gaussianf(x,a=a,μ=μ,σ=σ)*sin(2π*(f*x+phase))
function gaborf(x,y;a=1,μ₁=0,σ₁=1,μ₂=0,σ₂=1,θ=0,f=1,phase=0)
    sinv,cosv = sincos(θ)
    x′ = cosv * x + sinv * y
    y′ = cosv * y - sinv * x
    a*exp(-0.5(((x′-μ₁)/σ₁)^2 + ((y′-μ₂)/σ₂)^2)) * sin(2π*(f * y′ + phase))
end

"""
Properties of Circular Tuning:
    Prefered Direction/Orientation
    Selectivity Index
        version 1: (ResponsePrefered - ResponseOpposing)/ResponsePrefered
        version 2: (ResponsePrefered - ResponseOpposing)/(ResponsePrefered + ResponseOpposing)
    Full Width at Half Maximum

x: angles in radius
y: responses
od: opposing angle distance, π for DSI, 0.5π for OSI
s: symbol name
"""
function circtuningstats(x,y;od=π,s=od==π ? :d : :o)
    maxi = argmax(y)
    maxr = y[maxi]
    px = x[maxi]
    ox = px+od
    oi = findclosestangle(ox,x)
    or = y[oi]

    si1 = 1-or/maxr
    si2 = (maxr-or)/(maxr+or)

    # minr = minimum(y)
    # hmaxr = minr + (maxr-minr)/2
    @eval ($(Symbol(:p,s)) = $(rad2deg(mod(px,2od))), $(Symbol(s,:si1)) = $si1, $(Symbol(s,:si2)) = $si2)
end

"""
Tuning properties of factor response

fl: factor levels
fr: factor responses

    HueAngle, Orientation and Direction follow the same convention such that 0 is -/→, then increase counter-clock wise.
    For cases where Orientation and Direction are interlocked(drifting grating):
        when Orientation is -(0), then Direction is ↑(90)
        when Direction is →(0), then Orientation is |(-90)
"""
function factorresponsestats(fl,fr;factor=:Ori,thres=0.5)
    if factor in [:Ori,:Ori_Final]
        θ = deg2rad.(fl)
        d = mean(diff(sort(unique(θ)))) # angle spacing
        # for orientation
        oθ = mod.(θ,π)
        om = circmean(2oθ,fr)
        oo = rad2deg(mod(angle(om),2π)/2)
        ocv = circvar(2oθ,fr,2d)
        # for direction
        dm = circmean(θ.+0.5π,fr)
        od = rad2deg(mod(angle(dm),2π))
        dcv = circvar(θ.+0.5π,fr,d)
        # fit Generalized von Mises for direction
        fit = ()
        if thres > 0.5   # threshold here is based on AUC from ROC, if use p-values, should be (eg.) < 0.05
            try
                gvmfit = curve_fit((x,p)->gvmf.(x,p...),θ.+0.5π,fr,[1.0,0,1,0,1])
                if gvmfit.converged
                    x = 0:0.004:2π # 0.004rad = 0.23deg
                    y = gvmf.(x,gvmfit.param...)
                    fit = (circtuningstats(x,y,od=π,s=:d)...,gvm=gvmfit)
                end
            catch
            end
            # fit von Mises for orientation
            try
                vmfit = curve_fit((x,p)->vmf.(x,p...,n=2),θ,fr,[1.0,0,1])
                if vmfit.converged
                    x = 0:0.004:2π
                    y = vmf.(x,vmfit.param...,n=2)
                    fit = (fit...,circtuningstats(x,y,od=0.5π,s=:o)...,vm=vmfit)
                end
            catch
            end
        end

        return (dm=dm,od=od,dcv=dcv,om=om,oo=oo,ocv=ocv,fit=fit)
    elseif factor == :Dir
        θ = deg2rad.(fl)
        d = mean(diff(sort(unique(θ)))) # angle spacing
        # for orientation
        oθ = mod.(θ.-0.5π,π)
        om = circmean(2oθ,fr)
        oo = rad2deg(mod(angle(om),2π)/2)
        ocv = circvar(2oθ,fr,2d)
        # for direction
        dm = circmean(θ,fr)
        od = rad2deg(mod(angle(dm),2π))
        dcv = circvar(θ,fr,d)
        # fit Generalized von Mises for direction
        fit = ()
        if thres > 0.5   # threshold here is based on AUC from ROC, if use p-values, should be (eg.) < 0.05
            try
                gvmfit = curve_fit((x,p)->gvmf.(x,p...),θ,fr,[1.0,0,1,0,1])
                if gvmfit.converged
                    x = 0:0.004:2π # 0.004rad = 0.23deg
                    y = gvmf.(x,gvmfit.param...)
                    fit = (circtuningstats(x,y,od=π,s=:d)...,gvm=gvmfit)
                end
            catch
            end
            # fit von Mises for orientation
            try
                vmfit = curve_fit((x,p)->vmf.(x,p...,n=2),θ.-0.5π,fr,[1.0,0,1])
                if vmfit.converged
                    x = 0:0.004:2π
                    y = vmf.(x,vmfit.param...,n=2)
                    fit = (fit...,circtuningstats(x,y,od=0.5π,s=:o)...,vm=vmfit)
                end
            catch
            end
        end

        return (dm=dm,od=od,dcv=dcv,om=om,oo=oo,ocv=ocv,fit=fit)
    elseif factor == :SpatialFreq
        osf = 2^(sum(fr.*log2.(fl))/sum(fr)) # weighted average as optimal sf
        return (osf = osf,)
    elseif factor == :ColorID
        # transform colorId to hue angle
        ucid = sort(unique(fl))
        hstep = 2pi/length(ucid)
        ha = map(l->hstep*(findfirst(c->c==l,ucid)-1),fl)
        oh = mod(rad2deg(circmean(ha,fr)),360)
        ohv = circmeanv(ha,fr)
        ohr = circr(ha,fr)
        hcv = circvar(ha,fr)
        hm = circmean(ha,fr)
        oh = mod(rad2deg(angle(hm)),360)
        hcv = circvar(ha,fr,hstep)

        return (hm=hm,oh=oh,hcv=hcv)
    elseif factor == :HueAngle
        θ = deg2rad.(fl)
        d = mean(diff(sort(unique(θ)))) # angle spacing
        # for hue axis
        aθ = mod.(θ,π)
        ham = circmean(2aθ,fr)
        oha = rad2deg(mod(angle(ham),2π)/2)
        hacv = circvar(2aθ,fr,2d)
        # for hue
        hm = circmean(θ,fr)
        oh = rad2deg(mod(angle(hm),2π))
        hcv = circvar(θ,fr,d)
        maxi = argmax(fr)
        maxh = fl[maxi]
        maxr = fr[maxi]
        # fit Generalized von Mises for hue
        fit = ()
        if thres > 0.5   # threshold here is based on AUC from ROC, if use p-values, should be (eg.) < 0.05
            try
                gvmfit = curve_fit((x,p)->gvmf.(x,p...),θ,fr,[1.0,0,1,0,1])
                if gvmfit.converged
                    x = 0:0.004:2π # 0.004rad = 0.23deg
                    y = gvmf.(x,gvmfit.param...)
                    fit = (circtuningstats(x,y,od=π,s=:h)...,gvm=gvmfit)
                end
            catch
            end
            # fit von Mises for hue axis
            try
                vmfit = curve_fit((x,p)->vmf.(x,p...,n=2),θ,fr,[1.0,0,1])
                if vmfit.converged
                    x = 0:0.004:2π
                    y = vmf.(x,vmfit.param...,n=2)
                    fit = (fit...,circtuningstats(x,y,od=0.5π,s=:ha)...,vm=vmfit)
                end
            catch
            end
        end

        return (ham=ham,oha=oha,hacv=hacv,hm=hm,oh=oh,hcv=hcv,maxh=maxh,maxr=maxr,fit=fit)
    else
        return []
    end
end

"""
Spike Triggered Average of Images

- x: Matrix where each row is one image
- y: Vector of image response
"""
function sta(x::AbstractMatrix,y::AbstractVector;isnorm=true,whiten=nothing)
    r = x'*y
    if isnorm
        r/=sum(y)
    end
    if !isnothing(whiten)
        r = whiten * r
    end
    # if iswhiten
    #     r = x'*x\r
    #     r=length(y)*inv(cov(x,dims=1))*r
    # end
    return r
end


# function drv(p,n=1,isfreq=false)
#   d=Categorical(p)
#   if n==1
#     return rand(d)
#   end
#   if isfreq
#     pn = round(p[1:end-1]*n)
#     pn = [pn,n-sum(pn)]
#
#     pnc = zeros(Int,length(p))
#     ps = zeros(Int,n)
#     for i in 1:n
#       while true
#         v = rand(d)
#         if pnc[v] < pn[v]
#           pnc[v] += 1
#           ps[i]=v
#           break
#         end
#       end
#     end
#     return ps
#   else
#     rand(d,n)
#   end
# end
#
# function randvec3(xr::Vector,yr::Vector,zr::Vector)
#   dx = Uniform(xr[1],xr[2])
#   dy = Uniform(yr[1],yr[2])
#   dz = Uniform(zr[1],zr[2])
#   Vec3(rand(dx),rand(dy),rand(dz))
# end
# randvec3(;xmin=0,xmax=1,ymin=0,ymax=1,zmin=0,zmax=1)=randvec3([xmin,xmax],[ymin,ymax],[zmin,zmax])
# function randvec3(absmin::Vector)
#   d = Uniform(-1,1)
#   av3 = zeros(3)
#   for i=1:3
#     while true
#       r= rand(d)
#       if abs(r) >= absmin[i]
#         av3[i]=r
#         break;
#       end
#     end
#   end
#   return convert(Vec3,av3)
# end
# randvec3(xabsmin,yabsmin,zabsmin)=randvec3([xabsmin,yabsmin,zabsmin])
# function randvec3(radmin;is2d=false)
#   innerabsmin = radmin*sin(pi/4)
#   absmin = fill(innerabsmin,3)
#   while true
#     cv3 = randvec3(absmin)
#     if is2d;cv3.z=0.0;end
#     if length(cv3) >= radmin
#       return cv3
#     end
#   end
# end

# function convert(::Type{DataFrame},ct::CoefTable)
#    df = convert(DataFrame,ct.mat)
#    names!(df,map(symbol,ct.colnms))
#    [DataFrame(coefname=ct.rownms) df]
#end



# function flcond(fl,fs...)
#   if length(fs)==0
#     fs=collect(keys(fl))
#   end
#   ex = :([{(fs[1],l1)} for l1=fl[fs[1]]][:])
#   for i=2:length(fs)
#     lx=symbol("l$i")
#     push!(ex.args[1].args,:($lx=fl[fs[$i]]))
#     push!(ex.args[1].args[1].args,:((fs[$i],$lx)))
#   end
#   eval(ex)
# end
function flcond(fl,f1)
    conds = [Any[(f1,l1)] for l1 in fl[f1]]
end
function flcond(fl,f1,f2)
    conds = [Any[(f1,l1),(f2,l2)] for l1 in fl[f1],l2 in fl[f2]][:]
end
function flcond(fl,f1,f2,f3)
    conds = [Any[(f1,l1),(f2,l2),(f3,l3)] for l1 in fl[f1],l2 in fl[f2],l3 in fl[f3]][:]
end
function subcond(conds,sc...)
    sci = map(i->issubset(sc,i),conds)
    return conds[sci]
end


function findcond(df::DataFrame,cond)
    i = trues(size(df,1))
    for f in keys(cond)
        i .&= df[f].==cond[f]
    end
    return findall(i)
end
function findcond(df::DataFrame,cond::Vector{Any};roundingdigit=3)
    i = trues(size(df,1))
    condstr = ""
    for fl in cond
        f = fl[1]
        l = fl[2]
        i &= df[Symbol(f)].==l
        if typeof(l)<:Real
            lv=round(l,roundingdigit)
        else
            lv=l
        end
        condstr = "$condstr, $f=$lv"
    end
    return find(i),condstr[3:end]
end
function findcond(df::DataFrame,conds::Vector{Vector{Any}};roundingdigit=3)
    n = length(conds)
    is = Array(Vector{Int},n)
    ss = Array(String,n)
    for i in 1:n
        is[i],ss[i] = findcond(df,conds[i],roundingdigit=roundingdigit)
    end
    vi = map(i->!isempty(i),is)
    return is[vi],ss[vi],conds[vi]
end

"""
Find levels for each factor and indices, repetition for each level
"""
flin(ctc::Dict)=flin(DataFrame(ctc))
function flin(ctc::DataFrame)
    fl=OrderedDict()
    for f in names(ctc)
        fl[f] = condin(ctc[:,[f]])
    end
    return fl
end

"""
Find unique condition and indices, repetition for each
"""
condin(ctc::Dict)=condin(DataFrame(ctc))
function condin(ctc::DataFrame)
    t = [ctc DataFrame(i=1:nrow(ctc))]
    t = by(t, names(ctc),g->DataFrame(n=nrow(g), i=[g[:,:i]]))
    sort!(t);return t
end

"Get factors of conditions"
condfactor(cond::DataFrame)=setdiff(names(cond),[:n,:i])

"Get `Final` factors of conditions"
function finalfactor(cond::DataFrame)
    fs = String.(condfactor(cond))
    fs = filter(f->endswith(f,"_Final") || ∉("$(f)_Final",fs),fs)
    Symbol.(fs)
end

"Condition in String"
function condstring(cond::DataFrameRow,fs=names(cond))
    join(["$f=$(cond[f])" for f in fs],", ")
end
function condstring(cond::DataFrame,fs=names(cond))
    [condstring(r,fs) for r in eachrow(cond)]
end

"""
Group repeats of Conditions, get `Mean` and `SEM` of responses

rs: responses of each trial
gi: trial indices of repeats for each condition
"""
function condresponse(rs,gi)
    grs = [rs[i] for i in gi]
    DataFrame(m=mean.(grs),se=sem.(grs))
end
function condresponse(rs,cond::DataFrame;u=0,ug="U")
    crs = [rs[r[:i]] for r in eachrow(cond)]
    df = [DataFrame(m=mean.(crs),se=sem.(crs),u=fill(u,length(crs)),ug=fill(ug,length(crs))) cond[:,condfactor(cond)]]
end
function condresponse(urs::Dict,cond::DataFrame)
    vcat([condresponse(v,cond,u=k) for (k,v) in urs]...)
end
function condresponse(urs::Dict,ctc::DataFrame,factors)
    vf = filter(f->any(f.==factors),names(ctc))
    isempty(vf) && error("No Valid Factor Found.")
    condresponse(urs,condin(ctc[:,vf]))
end

"Condition Response in Factor Space"
function factorresponse(mseuc;factors = setdiff(names(mseuc),[:m,:se,:u,:ug]),fl = flin(mseuc[factors]),fa = OrderedDict(f=>fl[f][f] for f in keys(fl)))
    fm = missings(Float64, map(nrow,values(fl))...)
    fse = copy(fm)
    for i in 1:nrow(mseuc)
        idx = [findfirst(mseuc[i:i,f].==fa[f]) for f in keys(fa)]
        fm[idx...] = mseuc[i,:m]
        fse[idx...] = mseuc[i,:se]
    end
    return fm,fse,fa
end
function factorresponse(unitspike,ctc,condon,condoff;responsedelay=15)
    fms=[];fses=[];fa=[];cond=condin(ctc);factors = condfactor(cond)
    fl = flin(cond[:,factors]);fa = OrderedDict(f=>fl[f][f] for f in keys(fl))
    for u in 1:length(unitspike)
        rs = subrvr(unitspike[u],condon.+responsedelay,condoff.+responsedelay)
        mseuc = condresponse(rs,cond)
        fm,fse,_ = factorresponse(mseuc,factors=factors,fl=fl,fa=fa)
        push!(fms,fm);push!(fses,fse)
    end
    return fms,fses,fa
end

function setfln(fl::Dict,n::Int)
    fln=Dict()
    for f in keys(fl)
        for l in fl[f]
            fln[(f,l)] = n
        end
    end
    return fln
end
function setfln(fl::Dict,fn::Dict)
    fln=Dict()
    for f in keys(fl)
        for i=1:length(fl[f])
            fln[(f,fl[f][i])] = fn[f][i]
        end
    end
    return fln
end

function testfln(fln::Dict,minfln::Dict;showmsg::Bool=true)
    r=true
    for mkey in keys(minfln)
        if haskey(fln,mkey)
            if fln[mkey] < minfln[mkey]
                if showmsg;print("Level $(mkey[2]) of factor \"$(mkey[1])\" repeats $(fln[mkey]) < $(minfln[mkey]).\n");end
                r=false
            end
        else
            if showmsg;print("Level $(mkey[2]) of factor \"$(mkey[1])\" is missing.\n");end
            r=false
        end
    end
    return r
end
function testfln(ds::Vector,minfln::Dict;showmsg::Bool=true)
    vi = find(map(d->begin
    if showmsg;print("Testing factor/level of \"$(d["datafile"])\" ...\n");end
    testfln(d["fln"],minfln,showmsg=showmsg)
end,ds))
end

function condmean(rs,ridx,conds)
    nc = length(conds)
    m = Array(Float64,nc)
    sd = similar(m)
    n = Array(Int,nc)
    for i=1:nc
        r=rs[ridx[i]]
        m[i]=mean(r)
        sd[i]=std(r)
        n[i]=length(r)
    end
    return m,sd,n
end
function condmean(rs,us,ridx,conds)
    msdn = map(i->condmean(i,ridx,conds),rs)
    m= map(i->i[1],msdn)
    sd = map(i->i[2],msdn)
    n=map(i->i[3],msdn)
    return m,hcat(sd...),hcat(n...)
end

function psth(rvv::RVVector,binedges::RealVector,c;israte::Bool=true,normfun=nothing)
    m,se,x = psth(rvv,binedges,israte=israte,normfun=normfun)
    df = DataFrame(x=x,m=m,se=se,c=fill(c,length(x)))
end
function psth(rvv::RVVector,binedges::RealVector,cond::DataFrame;israte::Bool=true,normfun=nothing)
    fs = finalfactor(cond)
    vcat([psth(rvv[r[:i]],binedges,condstring(r,fs),israte=israte,normfun=normfun) for r in eachrow(cond)]...)
end
function psth(rvv::RVVector,binedges::RealVector,ctc::DataFrame,factor;israte::Bool=true,normfun=nothing)
    vf = filter(f->any(f.==factor),names(ctc))
    isempty(vf) && error("No Valid Factor Found.")
    psth(rvv,binedges,condin(ctc[:,vf]),israte=israte,normfun=normfun)
end

function psth(ds::DataFrame,binedges::RealVector,conds::Vector{Vector{Any}};normfun=nothing,spike=:spike,isse::Bool=true)
    is,ss = findcond(ds,conds)
    df = psth(map(x->ds[spike][x],is),binedges,ss,normfun=normfun)
    if isse
        df[:ymin] = df[:y]-df[:ysd]./sqrt(df[:n])
        df[:ymax] = df[:y]+df[:ysd]./sqrt(df[:n])
    end
    return df,ss
end
function psth(rvvs::RVVVector,binedges::RealVector,conds;normfun=nothing)
    n = length(rvvs)
    n!=length(conds) && error("Length of rvvs and conds don't match.")
    dfs = [psth(rvvs[i],binedges,conds[i],normfun=normfun) for i=1:n]
    return cat(1,dfs)
end
function spacepsth(unitpsth,unitposition;spacebinedges=range(0,step=20,length=ceil(Int,maximum(unitposition[:,2])/20)))
    ys,ns,ws,is = subrv(unitposition[:,2],spacebinedges)
    x = unitpsth[1][3]
    nbins = length(is)
    um = map(i->i[1],unitpsth)
    use = map(i->i[2],unitpsth)
    spsth = zeros(nbins,length(x))
    for i in 1:nbins
        if length(is[i]) > 0
            spsth[i,:] = mean(hcat(um[is[i]]...),dims=2)
        end
    end
    binwidth = ws[1][2]-ws[1][1]
    bincenters = [ws[i][1]+binwidth/2.0 for i=1:nbins]
    return spsth,x,bincenters,ns
end


"""
Shift(shuffle) corrected, normalized(coincidence/spike), condition/trial-averaged Cross-Correlogram of binary spike trains.
(Bair, W., Zohary, E., and Newsome, W.T. (2001). Correlated Firing in Macaque Visual Area MT: Time Scales and Relationship to Behavior. J. Neurosci. 21, 1676–1697.)
"""
function correlogram(bst1,bst2;lag=nothing,isnorm=true,shiftcorrection=true,condis=nothing)
    if !isnothing(condis)
        cccg=[];x=[]
        for ci in condis
            ccg,x = correlogram(bst1[:,ci],bst2[:,ci],lag=lag,isnorm=isnorm,shiftcorrection=shiftcorrection,condis=nothing)
            push!(cccg,ccg)
        end
        ccg=dropdims(mean(hcat(cccg...),dims=2),dims=2)
        return ccg,x
    end
    n,nepoch = size(bst1)
    lag = floor(Int,isnothing(lag) ? min(n-1, 10*log10(n)) : lag)
    x = -lag:lag;xn=2lag+1
    cc = Array{Float64}(undef,xn,nepoch)
    for k in 1:nepoch
        cc[:,k]=crosscov(bst1[:,k],bst2[:,k],x,demean=false)*n
    end
    ccg = dropdims(mean(cc,dims=2),dims=2)
    if isnorm
        λ1 = mean(mean(bst1,dims=1))
        λ2 = mean(mean(bst2,dims=1))
        gmsr = sqrt(λ1*λ2)
        Θ = n.-abs.(x)
        normfactor = 1 ./ Θ ./ gmsr
    end
    if shiftcorrection
        psth1 = dropdims(mean(bst1,dims=2),dims=2)
        psth2 = dropdims(mean(bst2,dims=2),dims=2)
        s = crosscov(psth1,psth2,x,demean=false)*n
        shiftccg = (nepoch*s .- ccg)/(nepoch-1)
        if isnorm
            ccg .*= normfactor
            shiftccg .*= normfactor
        end
        ccg .-= shiftccg
    elseif isnorm
        ccg .*= normfactor
    end
    ccg,x
end
function circuitestimate(unitbinspike;lag=nothing,maxprojlag=3,minepoch=5,minspike=10,esdfactor=5,isdfactor=3.5,unitid=[],condis=nothing)
    nunit=length(unitbinspike)
    n,nepoch = size(unitbinspike[1])
    lag = floor(Int,isnothing(lag) ? min(n-1, 10*log10(n)) : lag)
    x = -lag:lag;xn=2lag+1

    isenoughspike = (i,j;minepoch=5,minspike=10) -> begin
        vsi = sum(i,dims=1)[:] .>= minspike
        vsj = sum(j,dims=1)[:] .>= minspike
        count(vsi) >= minepoch && count(vsj) >= minepoch
    end

    ccgs=[];ccgis=[];projs=[];eunits=[];iunits=[];projweights=[]
    for (i,j) in combinations(1:nunit,2)
        if isnothing(condis)
            !isenoughspike(unitbinspike[i],unitbinspike[j],minepoch=minepoch,minspike=minspike) && continue
            vcondis=nothing
        else
            vci = map(ci->isenoughspike(unitbinspike[i][:,ci],unitbinspike[j][:,ci],minepoch=minepoch,minspike=minspike),condis)
            all(.!vci) && continue
            vcondis = condis[vci]
        end

        ccg,_ = correlogram(unitbinspike[i],unitbinspike[j],lag=lag,condis=vcondis)
        ps,es,is,pws = projectionfromcorrelogram(ccg,i,j,maxprojlag=maxprojlag,esdfactor=esdfactor,isdfactor=isdfactor)
        if !isempty(ps)
            push!(ccgs,ccg);push!(ccgis,(i,j))
            append!(projs,ps);append!(eunits,es);append!(iunits,is);append!(projweights,pws)
        end
    end
    unique!(eunits);unique!(iunits)
    if length(unitid)==nunit
        map!(t->(unitid[t[1]],unitid[t[2]]),ccgis,ccgis)
        map!(t->(unitid[t[1]],unitid[t[2]]),projs,projs)
        map!(t->unitid[t],eunits,eunits)
        map!(t->unitid[t],iunits,iunits)
    end
    return ccgs,x,ccgis,projs,eunits,iunits,projweights
end
function projectionfromcorrelogram(cc,i,j;maxprojlag=3,minbaselag=maxprojlag+1,esdfactor=5,isdfactor=5)
    midi = Int((length(cc)+1)/2)
    base = vcat(cc[midi+minbaselag:end],cc[1:midi-minbaselag])
    bm,bsd = mean_and_std(base);hl = bm + esdfactor*bsd;ll = bm - isdfactor*bsd
    forwardlags = midi+1:midi+maxprojlag
    backwardlags = midi-maxprojlag:midi-1
    fcc = cc[forwardlags]
    bcc = cc[backwardlags]
    ps=[];ei=[];ii=[];pws=[]

    if ll <= cc[midi] <= hl
        if any(fcc .> hl)
            push!(ps,(i,j));push!(ei,i);push!(pws,(maximum(fcc)-bm)/bsd)
        elseif any(fcc .< ll)
            push!(ps,(i,j));push!(ii,i);push!(pws,(minimum(fcc)-bm)/bsd)
        end
        if any(bcc .> hl)
            push!(ps,(j,i));push!(ei,j);push!(pws,(maximum(bcc)-bm)/bsd)
        elseif any(bcc .< ll)
            push!(ps,(j,i));push!(ii,j);push!(pws,(minimum(bcc)-bm)/bsd)
        end
    end
    return ps,ei,ii,pws
end

function checklayer(ls::Dict)
    ln=["WM","6","5","5/6","4Cb","4Ca","4C","4B","4A","4A/B","3","2","2/3","1","Out"]
    n = length(ln)
    for i in 1:n-1
        if haskey(ls,ln[i])
            for j in (i+1):n
                if haskey(ls,ln[j])
                    ls[ln[i]][2] = ls[ln[j]][1]
                    break
                end
            end
        end
    end
    return ls
end

function assignlayer(ys,layer)
    ls = []
    for y in ys
        for k in keys(layer)
            if layer[k][1] <= y < layer[k][2]
                push!(ls,k);break
            end
        end
    end
    return ls
end

function checkcircuit(projs,eunits,iunits,projweights)
    ivu = intersect(eunits,iunits)
    veunits = setdiff(eunits,ivu)
    viunits = setdiff(iunits,ivu)
    ivp = map(p->any(i->i in ivu,p),projs)
    vprojs = deleteat!(copy(projs),ivp)
    vprojweights = deleteat!(copy(projweights),ivp)
    return vprojs,veunits,viunits,vprojweights
end
