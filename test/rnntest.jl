using Base.Test
using CUDArt
using KUnet

# import KUnet: forw, back, ninputs, param, similar!, gpu, initforw, initback, push, pop, get1
# include("../src/net.jl")

include("isapprox.jl")

info("TEST 5")

isdefined(:MNIST) || include("mnist.jl")
net = [Drop(0.5), Conv(20,5), Bias(), Relu(), Pool(2),
       Drop(0.5), Conv(50,5), Bias(), Relu(), Pool(2),
       Drop(0.5), Mmul(500), Bias(), Relu(),
       Drop(0.5), Mmul(10), Bias(), XentLoss()]

nb = 128
x = KUdense(gpucopy(reshape(MNIST.xtrn[:,1:nb],28,28,1,nb)))
forw(net, copy(x))   # initializes the weights
rnn = Net(gpucopy(net)...)

setseed(42)
# @date y1 = forw(net, copy(x))
ybuf1 = Array(Any, length(net))
y = copy(x)
for n=1:length(net)
    y = forw(net[n], y)
    ybuf1[n] = cpucopy(y.arr)
end
y1 = y
    
setseed(42)
init(rnn)
ybuf2 = Array(Any, length(net))
y = copy(x)
inputs = Any[y]
train1 = true
a = ()
r = rnn
initforw(r, inputs...)                      # alloc space if necessary
for i = 1:ninputs(r)
    n = i+nops(r)                           # input[i] goes into out[i+nops(r)]
    train1 && r.save[n] && push(r,n)         # save old input if necessary
    r.out[n] = copy!(r.out0[n], inputs[i])  # inputs can be any type of array, this will copy it to gpu or wherever
end                                         # println("in[$i]=$(map(idx1,inputs)) st=$(map(idx1,r.stack[1:r.sp]))")
for n = 1:nops(r)
    train1 && r.save[n] && push(r,n)         # TODO: (minor) this ends up using a lot of nothing pushes first minibatch
    r.out[n] = forw(r.op[n], r.out[r.inputs[n]]...; y=r.out0[n], a...)
    ybuf2[n] = cpucopy(r.out[n].arr)
end                                         # println("op[$n]:$((typeof(r.op[n],map(idx1,getx(r,n))...,idx1(gety(r,n)))) st=$(map(idx1,r.stack[1:r.sp]))")
y2 = r.out[nops(r)]

@test @show to_host(y1.arr)==to_host(y2.arr)

y = KUdense(gpucopy(MNIST.ytrn[:,1:nb]))

# @date back(net, copy(y))
dy = copy(y)
dybuf1 = Array(Any, length(net))
for n=length(net):-1:1
    dy = back(net[n], dy)
    # @show (n, to_host(dy)[1])
    dybuf1[n] = cpucopy(dy.arr)
end

# @date back(rnn, copy(y))
r = rnn
dy = copy(y)
dybuf2 = Array(Any, nops(r))
initback(r)
n = nops(r)
r.dif[n] = copy!(r.dif0[n], dy)             # println("back:dy=$((idx1(getdy(r,nops(r))),))")    
for n = nops(r):-1:1
    if r.dif[n] != nothing                  # 'nothing' represents 0 loss gradient
        dx = map(r.inputs[n]) do i; r.inc[i]!=nothing ? r.inc[i] : (r.dif[i]=r.dif0[i]); end
        dy = back(r.op[n], r.dif[n]; incr=true, x=get1(r.out[r.inputs[n]]), y=r.out[n], dx=get1(dx), a...)

### back gives eq for layers 18..8, approxeq for layers 7..1
        dybuf2[n] = cpucopy(dy.arr)
        dytest1 = isapprox(dybuf1[n], dybuf2[n])
        @test dytest1
        dytest2 = (dybuf1[n] == dybuf2[n])
        p1 = map(p->p.diff, params(rnn.op[n]))
        p2 = map(p->p.diff, params(net[n]))
        @test dwtest1 = all(map(isapprox, p1, p2))
        dwtest2 = all(map(isequal, p1, p2))
        println((n, typeof(rnn.op[n]), dytest1, dytest2, dwtest1, dwtest2))
###

        for i in r.inputs[n]; r.inc[i]!=nothing && axpy!(1, r.inc[i], r.dif[i]); end
        r.inc[n]!=nothing && fill!(r.dif[n],0)
    end                                     # println("op[$n]:$((typeof(r.op[n]),:x,map(idx1,getx(r,n))...,:y,idx1(gety(r,n)),:dy,idx1(getdy(r,n)),:dx,map(idx1,getdxbuf(r,n))...)) st=$(map(idx1,r.stack[1:r.sp]))")
    r.save[n] && pop(r,n)                   # println("pop[$n]:y=$((idx1(gety(r,n)),)) st=$(map(idx1,r.stack[1:r.sp]))")
end
for i = ninputs(r):-1:1                     # println("in[$i]=$(map(idx1,(getinput(r,i),))) st=$(map(idx1,r.stack[1:r.sp]))")
    n = i+nops(r)                           # println("in[$i]=$(map(idx1,(getinput(r,i),))) st=$(map(idx1,r.stack[1:r.sp]))")
    r.save[n] && pop(r,n)
end


if true

info("TEST 4")

isdefined(:MNIST) || include("mnist.jl")
setseed(42)
net = [Conv(20,5), Bias(), Relu(), Pool(2),
       Conv(50,5), Bias(), Relu(), Pool(2),
       Mmul(500), Bias(), Relu(),
       Mmul(10), Bias(), XentLoss()]

nb = 128
x = KUdense(gpucopy(reshape(MNIST.xtrn[:,1:nb],28,28,1,nb)))
@date y1 = forw(net, copy(x))   # also initializes the weights
rnn = Net(gpucopy(net)...)
@date y2 = forw(rnn, copy(x))
@test @show to_host(y1.arr)==to_host(y2.arr)

y = KUdense(gpucopy(MNIST.ytrn[:,1:nb]))
@date back(net, copy(y))
@date back(rnn, copy(y))
for i=nops(rnn):-1:1
    isempty(params(net[i])) && continue
    p1 = map(p->p.diff, params(rnn.op[i]))
    p2 = map(p->p.diff, params(net[i]))
    print("$i "); @test @show all(map(isapprox, p1, p2))
    print("$i "); @show all(map(isequal, p1, p2)) # 1,2,5 only approx
end

info("TEST 3")

x = KUdense(gpucopy(rand(784,10)))
net = Op[Mmul(10),QuadLoss()]
@date y1 = forw(net, copy(x))
rnn = Net(gpucopy(net)...)
@date y2 = forw(rnn, copy(x))
@test @show to_host(y1.arr)==to_host(y2.arr)
dy = rand!(copy(y1))
back(net, copy(dy))
back(rnn, copy(dy))
for i=1:nops(rnn)
    isempty(params(net[i])) && continue
    p1 = map(p->p.diff, params(rnn.op[i]))
    p2 = map(p->p.diff, params(net[i]))
    print("$i "); @test @show all(map(isequal, p1, p2)) # 1,2,5 only approx
end

info("TEST 2")

isdefined(:MNIST) || include("mnist.jl")
setseed(42)
nb = 100
x = KUdense(gpucopy(MNIST.xtrn[:,1:nb]))
net = [Mmul(64), Bias(), Relu(), 
       Mmul(10), Bias(), XentLoss()]
@date y1 = forw(net, copy(x))

rnn = Net(gpucopy(net)...)
@date y2 = forw(rnn, copy(x))

# @show isapprox(y1,y2)
@test @show to_host(y1.arr)==to_host(y2.arr)

y = KUdense(gpucopy(MNIST.ytrn[:,1:nb]))
back(net, copy(y))
back(rnn, copy(y))
for i=1:nops(rnn)
    isempty(params(net[i])) && continue
    p1 = map(p->p.diff, params(rnn.op[i]))
    p2 = map(p->p.diff, params(net[i]))
    print("$i "); @test @show all(map(isequal, p1, p2)) # 1,2,5 only approx
end

info("TEST 1")
# irnn(h)=Net(Mmul(h), (Mmul(h),5), Add2(), Bias(), Relu())
# add1(h)=Net(Mmul(h), (Mmul(h),-1), Add2(), Bias(), Sigm())
# add2(h)=Net(Mmul(h), (Mmul(h),-1), Add2(), Bias(), Tanh())
# lstm(h)=Net((add1(h),0,9),      # 1. i
#             (add1(h),0,9),      # 2. f
#             (add1(h),0,9),      # 3. o
#             (add2(h),0,9),      # 4. cc
#             (Mul2(),1,4),       # 5. i*cc
#             (Mul2(),2,7),       # 6. f*c[t-1]
#             Add2(),             # 7. c
#             Tanh(),             # 8. tanh(c)
#             (Mul2(),3,8))       # 9. o * tanh(c)

function testops(a,ops)
    nops(a) == length(ops) || return false
    for i=1:nops(a)
        isa(a.op[i], ops[i]) || return false
    end
    return true
end

a = irnn(10)
aops = [Mmul, Mmul, Add2, Bias, Relu]
@test testops(a, aops)
@test a.inputs == Any[[6],[5],[1,2],[3],[4]]
@test a.ninputs == 1
@test find(a.save) == [5,6]
#@test a.y == [1,2,1,1,1,3]
#@test a.dy == [5,4,5,5,6,7]
#@test all(a.out .== nothing)
#@test all(a.out0 .== nothing)
@test a.stack == Any[]
@test a.sp == 0

b = Net(irnn(10),irnn(10))
bops = vcat(aops,aops)
@test testops(b, bops)
@test b.inputs == Any[[11],[5],[1,2],[3],[4],[5],[10],[6,7],[8],[9]]
@test b.ninputs == 1
@test find(b.save) == [5,10,11]
#@test b.y == [1,2,1,1,1,3,4,3,3,3,5]
#@test b.dy == [7,6,7,7,8,10,9,10,10,11,12]
#@test all(b.out .== nothing)
#@test b.out0 == b.out
@test b.stack == Any[]
@test b.sp == 0

c = lstm(10)
cops = [Mmul,Mmul,Add2,Bias,Sigm,Mmul,Mmul,Add2,Bias,Sigm,Mmul,Mmul,Add2,Bias,Sigm,Mmul,Mmul,Add2,Bias,Tanh,Mul2,Mul2,Add2,Tanh,Mul2]
@test testops(c, cops)
@test c.inputs == Any[[26],[25],[1,2],[3],[4],[26],[25],[6,7],[8],[9],[26],[25],[11,12],[13],[14],[26],[25],[16,17],[18],[19],[5,20],[10,23],[21,22],[23],[15,24]]
@test c.ninputs == 1
@test find(c.save) == [5,10,15,20,23,24,25,26]
#@test c.y == [1,2,1,1,1,3,4,3,3,3,5,6,5,5,5,7,8,7,7,7,9,10,9,11,12,13]
#@test c.dy == [15,14,15,15,15,17,16,17,17,17,19,18,19,19,19,21,20,21,21,21,22,23,24,25,26,27]
#@test all(c.out .== nothing)
#@test c.out0 == c.out
@test c.stack == Any[]
@test c.sp == 0

:ok

end # if false