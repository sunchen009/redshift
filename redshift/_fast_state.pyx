from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy
from _state cimport Kernel, Subtree

cdef enum:
    ERR
    SHIFT
    REDUCE
    LEFT
    RIGHT
    EDIT
    ASSIGN_POS
    N_MOVES

cdef FastState* init_fast_state() except NULL:
    cdef FastState* s = <FastState*>calloc(1, sizeof(FastState))
    s.knl.i = 1
    return s


cdef bint can_push(Kernel* k, size_t t):
    return k.i < (t-1) 


cdef bint has_stack(Kernel* k):
    return k.s0 != 0


cdef bint has_head(Kernel* k):
    return k.Ls0 != 0

cdef bint is_finished(Kernel* k, size_t t):
    return (not can_push(k, t)) and (not has_stack(k))


cdef int shift_kernel(Kernel* result, Kernel* parent) except -1:
    result.i = parent.i + 1
    result.s0 = parent.i
    result.s1 = parent.s0
    result.s2 = parent.s1
    result.Ls0 = 0
    result.Ls1 = parent.Ls0
    result.Ls2 = parent.Ls1
    # Parents of s0, e.g. hs0, h2s0, Lhs0 etc all null in Shift
    memcpy(&result.s0l, &parent.n0l, sizeof(Subtree))
    assert result.s0r.val == 0
    assert result.s0r.idx[0] == 0
    assert result.n0l.val == 0
    assert result.n0l.idx[0] == 0


cdef int right_kernel(Kernel* ext, Kernel* buff, size_t label) except -1:
    shift_kernel(ext, buff)
    ext.Ls0 = label
    # The child-of features are set in Reduce, not here, because that's when
    # that word becomes top of the stack again.


cdef int reduce_kernel(Kernel* ext, Kernel* buff, Kernel* stack) except -1:
    memcpy(ext, stack, sizeof(Kernel))
    memcpy(&ext.n0l, &buff.n0l, sizeof(Subtree))
    ext.i = buff.i
    # Reduce means that former-S0 is child of the next item on the stack. Set
    # the dep features here
    ext.s0r.idx[0] = buff.s0
    ext.s0r.idx[1] = stack.s0r.idx[0]
    #ext.s0r.idx[2] = stack.s0r.idx[1]
    #ext.s0r.idx[3] = stack.s0r.idx[2]
    ext.s0r.lab[0] = buff.Ls0
    ext.s0r.lab[1] = stack.s0r.lab[0]
    #ext.s0r.lab[2] = stack.s0r.lab[1]
    #ext.s0r.lab[3] = stack.s0r.lab[2]
    ext.s0r.val = stack.s0r.val + 1


cdef int left_kernel(Kernel* ext, Kernel* buff, Kernel* stack,
                           size_t label) except -1:
    if stack != NULL:
        ext.s0 = stack.s0
        ext.s1 = stack.s1
        ext.s2 = stack.s2
        ext.Ls0 = stack.Ls0
        ext.Ls1 = stack.Ls1
        ext.Ls2 = stack.Ls2
        memcpy(&ext.s0l, &stack.s0l, sizeof(Subtree))
        memcpy(&ext.s0r, &stack.s0r, sizeof(Subtree))
    ext.i = buff.i
    ext.n0l.val = buff.n0l.val + 1
    ext.n0l.idx[0] = buff.s0
    ext.n0l.idx[1] = buff.n0l.idx[0]
    #ext.n0l.idx[2] = buff.n0l.idx[1]
    #ext.n0l.idx[3] = buff.n0l.idx[2]
    ext.n0l.lab[0] = label
    ext.n0l.lab[1] = buff.n0l.lab[0]
    #ext.n0l.lab[2] = buff.n0l.lab[1]
    #ext.n0l.lab[3] = buff.n0l.lab[2]
    if ext.n0l.val >= 2:
        assert ext.n0l.idx[1] != 0
        assert ext.n0l.lab[1] != 0


cdef FastState* extend_fstate(FastState* prev, size_t move, size_t label, size_t clas,
                              double local_score, int cost) except NULL: 
    assert prev != NULL
    cdef FastState* ext = <FastState*>calloc(1, sizeof(FastState))
    if move == SHIFT:
        shift_kernel(&ext.knl, &prev.knl)
        ext.tail = prev
        ext.prev = prev
    elif move == RIGHT:
        right_kernel(&ext.knl, &prev.knl, label)
        ext.tail = prev
        ext.prev = prev
    elif move == REDUCE:
        assert prev != NULL
        assert prev.prev != NULL
        assert prev.tail != NULL
        reduce_kernel(&ext.knl, &prev.knl, &prev.tail.knl)
        ext.prev = prev
        ext.tail = prev.tail.tail
    elif move == LEFT:
        left_kernel(&ext.knl, &prev.knl, &prev.tail.knl, label)
        ext.tail = prev.tail.tail
        ext.prev = prev
    else:
        raise StandardError
    ext.score = prev.score + local_score
    ext.cost = prev.cost + cost
    ext.clas = clas
    return ext


cdef int fill_hist(size_t* hist, FastState* s, int t) except -1:
    while t >= 1 and s.prev != NULL:
        t -= 1
        hist[t] = s.clas
        s = s.prev


DEF MAX_STACK = 256
cdef int fill_stack(size_t* stack, FastState* s) except -1:
    cdef size_t t = 0
    while s != NULL:
        stack[t] = s.knl.s0
        s = s.tail
        t += 1
        assert t < MAX_STACK
    return t


cdef int fill_parse(size_t* heads, size_t* labels, FastState* s) except -1:
    cdef size_t cnt = 0
    while s != NULL:
        # Take the last set head, to support non-monotonicity
        # Take the heads from states just after right and left arcs
        if s.knl.Ls0 != 0 and heads[s.knl.s0] == 0:
            heads[s.knl.s0] = s.knl.s1
            labels[s.knl.s0] = s.knl.Ls0
        if s.knl.n0l.idx[0] != 0 and heads[s.knl.n0l.idx[0]] == 0:
            heads[s.knl.n0l.idx[0]] = s.knl.i
            labels[s.knl.n0l.idx[0]] = s.knl.n0l.lab[0]
        s = s.prev
        cnt += 1
        assert cnt < 100000
