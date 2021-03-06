export circuit_extraction

"""
    circuit_extraction(zxg::ZXGraph)

Extract circuit from a graph-like ZX-diagram.
"""
function circuit_extraction(zxg::ZXGraph{T, P}) where {T, P}
    nzxg = copy(zxg)
    nbits = nqubits(zxg)

    cir = ZXDiagram(nbits)
    set_global_phase!(cir, global_phase(zxg))
    Outs = get_outputs(nzxg)
    Ins = get_inputs(nzxg)
    if length(Outs) != length(Ins)
        return cir
    end
    if nbits == 0
        nbits = length(Outs)
    end
    for v1 in Ins
        @inbounds v2 = neighbors(nzxg, v1)[1]
        if !is_hadamard(nzxg, v1, v2)
            insert_spider!(nzxg, v1, v2)
        end
    end
    @inbounds frontier = [neighbors(nzxg, v)[1] for v in Outs]

    extracted = copy(Outs)

    for i = 1:nbits
        @inbounds w = neighbors(zxg, Outs[i])[1]
        @inbounds if is_hadamard(nzxg, w, Outs[i])
            pushfirst_gate!(cir, Val{:H}(), i)
        end
        pushfirst_gate!(cir, Val{:Z}(), i, phase(nzxg, w))
        set_phase!(nzxg, w, zero(P))
        @inbounds rem_edge!(nzxg, w, Outs[i])
    end
    for i = 1:nbits
        for j = i+1:nbits
            @inbounds if has_edge(nzxg, frontier[i], frontier[j])
                if is_hadamard(nzxg, frontier[i], frontier[j])
                    pushfirst_gate!(cir, Val{:CZ}(), i, j)
                    rem_edge!(nzxg, frontier[i], frontier[j])
                end
            end
        end
    end
    extracted = [extracted; frontier]

    while !isempty(setdiff(spiders(nzxg), extracted))
        frontier = update_frontier!(nzxg, frontier, cir)
        extracted = union!(extracted, frontier)
    end

    frontier = T[]
    for v in Ins
        nb = neighbors(nzxg, v)
        if length(nb) > 0
            push!(frontier, nb[])
        end
    end
    sort!(frontier, by = (v->qubit_loc(nzxg, v)))
    M = biadjancency(nzxg, frontier, Ins)
    M, steps = gaussian_elimination(M)
    for step in steps
        if step.op == :swap
            q1 = step.r1
            q2 = step.r2
            pushfirst_gate!(cir, Val{:CNOT}(), q2, q1)
            pushfirst_gate!(cir, Val{:CNOT}(), q1, q2)
            pushfirst_gate!(cir, Val{:CNOT}(), q2, q1)
        end
    end

    simplify!(Rule{:i1}(), cir)
    simplify!(Rule{:i2}(), cir)
    return cir
end

"""
    update_frontier!(zxg, frontier, cir)

Update frontier. This is a important step in the circuit extraction algorithm.
For more detail, please check the paper [arXiv:1902.03178](https://arxiv.org/abs/1902.03178).
"""
function update_frontier!(zxg::ZXGraph{T, P}, frontier::Vector{T}, cir::ZXDiagram{T, P}) where {T, P}
    frontier = frontier[[spider_type(zxg, f) == SpiderType.Z && (degree(zxg, f)) > 0 for f in frontier]]
    SetN = Set{T}()
    for f in frontier
        union!(SetN, neighbors(zxg, f))
    end
    N = collect(SetN)
    sort!(N, by = v -> qubit_loc(zxg, v))
    M = biadjancency(zxg, frontier, N)
    M0, steps = gaussian_elimination(M)
    ws = T[]
    @inbounds for i = 1:length(frontier)
        if sum(M0[i,:]) == 1
            push!(ws, N[findfirst(isone, M0[i,:])])
        end
    end
    M1 = biadjancency(zxg, frontier, ws)
    @inbounds for e in findall(M .== 1)
        if has_edge(zxg, frontier[e[1]], N[e[2]])
            rem_edge!(zxg, frontier[e[1]], N[e[2]])
        end
    end
    @inbounds for e in findall(M0 .== 1)
        add_edge!(zxg, frontier[e[1]], N[e[2]])
    end

    @inbounds for step in steps
        if step.op == :addto
            ctrl = qubit_loc(zxg, frontier[step.r2])
            loc = qubit_loc(zxg, frontier[step.r1])
            pushfirst_gate!(cir, Val{:CNOT}(), loc, ctrl)
        else
            q1 = qubit_loc(zxg, frontier[step.r1])
            q2 = qubit_loc(zxg, frontier[step.r2])

            pushfirst_gate!(cir, Val{:CNOT}(), q2, q1)
            pushfirst_gate!(cir, Val{:CNOT}(), q1, q2)
            pushfirst_gate!(cir, Val{:CNOT}(), q2, q1)
        end
    end
    old_frontier = copy(frontier)
    @inbounds for w in ws
        nb_w = neighbors(zxg, w)
        v = intersect(nb_w, old_frontier)[1]
        if (degree(zxg, v)) == 1
            qubit_v = qubit_loc(zxg, v)
            qubit_w = qubit_loc(zxg, w)
            pushfirst_gate!(cir, Val{:H}(), qubit_v)
            if spider_type(zxg, w) == SpiderType.Z
                pushfirst_gate!(cir, Val{:Z}(), qubit_v, phase(zxg, w))
                set_phase!(zxg, w, zero(P))
            end
            if qubit_v != qubit_w && spider_type(zxg, w) == SpiderType.Z
                loc_v = column_loc(zxg, v)
                loc_w = column_loc(zxg, w)
                set_loc!(zxg.layout, w, qubit_v, loc_v)
                set_column!(zxg.layout, v, loc_v+1//2)
                # deleteat!(zxg.layout.spider_seq[qubit_w], loc_w)
                # insert!(zxg.layout.spider_seq[qubit_v], loc_v, w)
            end
            rem_edge!(zxg, v, w)
            if spider_type(zxg, w) == SpiderType.In
                add_edge!(zxg, w, v, 1)
            end
            deleteat!(frontier, frontier .== v)
            push!(frontier, w)
        end
    end
    @inbounds for i1 = 1:length(ws)
        for i2 = i1+1:length(ws)
            if has_edge(zxg, ws[i1], ws[i2])
                pushfirst_gate!(cir, Val{:CZ}(), qubit_loc(zxg, ws[i1]),
                    qubit_loc(zxg, ws[i2]))
                rem_edge!(zxg, ws[i1], ws[i2])
            end
        end
    end
    sort!(frontier, by = v -> qubit_loc(zxg, v))
    return frontier
end

"""
    biadjancency(zxg, F, N)

Return the biadjancency matrix of `zxg` from vertices in `F` to vertices in `N`.
"""
function biadjancency(zxg::ZXGraph{T, P}, F::Vector{T}, N::Vector{T}) where {T, P}
    M = zeros(Int, length(F), length(N))

    for i = 1:length(F)
        for v2 in neighbors(zxg, F[i])
            if v2 in N
                M[i, findfirst(isequal(v2), N)] = 1
            end
        end
    end
    return M
end

"""
    GEStep

A struct for representing steps in the Gaussian elimination.
"""
struct GEStep
    op::Symbol
    r1::Int
    r2::Int
end

"""
    gaussian_elimination(M[, steps])

Return result and steps of Gaussian elimination of matrix `M`. Here we assume
that the elements of `M` is in binary field F_2 = {0,1}.
"""
function gaussian_elimination(M::Matrix{T}, steps::Vector{GEStep} = Vector{GEStep}()) where {T<:Integer}
    M = copy(M)
    nr, nc = size(M)
    current_col = 1
    for i = 1:nr
        if sum(M[i,:]) == 0
            continue
        end
        while current_col <= nc
            r0 = findfirst(!iszero, M[i:nr, current_col])
            if r0 != nothing
                r0 += i - 1
                r0 == i && break
                r_temp = M[i,:]
                M[i,:] = M[r0,:]
                M[r0,:] = r_temp
                step = GEStep(:swap, i, r0)
                push!(steps, step)
                break
            else
                current_col += 1
            end
        end
        current_col > nc && break
        for j = 1:nr
            j == i && continue
            if M[j, current_col] == M[i, current_col]
                M[j,:] = M[j,:] .⊻ M[i,:]
                step = GEStep(:addto, i, j)
                push!(steps, step)
            end
        end
        current_col += 1
    end
    return M, steps
end

"""
    reverse_gaussian_elimination(M, steps)

Apply back the operations in `steps` to `M`.
"""
function reverse_gaussian_elimination(M, steps)
    for i = length(steps):-1:1
        s = steps[i]
        op = s.op
        r1 = s.r1
        r2 = s.r2
        if op == :addto
            M[r2,:] = M[r2,:] .⊻ M[r1,:]
        else
            r_temp = M[r1,:]
            M[r1,:] = M[r2,:]
            M[r2,:] = r_temp
        end
    end
    return M
end
