# -*- coding: utf-8 -*-
# Copyright 2014-2015 Michael Helmling
# cython: boundscheck=True
# cython: nonecheck=True
# cython: cdivision=False
# cython: wraparound=True
# cython: initializedcheck=True
# cython: language_level=3
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation

import logging
import itertools
import random
from collections import OrderedDict

from libc.math cimport fabs, fmin, fmax
import numpy as np
cimport numpy as np
from numpy.math cimport INFINITY

from lpdec.decoders.base cimport Decoder
from lpdec.decoders.adaptivelp_glpk import AdaptiveLPDecoder
from lpdec.decoders.iterative import IterativeDecoder
from lpdec.decoders.branchcut.node cimport Node, move
from lpdec.decoders.branchcut.branching cimport BranchingRule
from lpdec.decoders.branchcut.branching import MostFractional, FirstFractional, LeastReliable, ReliabilityBranching
from lpdec import gfqla, utils, persistence

logger = logging.getLogger(name='branchcut-decoder')


cdef enum SelectionMethod:
    mixed, dfs, bbs


cdef class BranchAndCutDecoder(Decoder):
    """
    Maximum-Likelihood decoder using a branch-and-cut approach. Upper bounds (i.e. valid
    solutions) are generated using the max-product algorithm from :class:`IterativeDecoder`.
    Lower bounds and cuts are generated with :class:`AdaptiveLPDecoder`.

    :param str branchMethod: Method to determine the (fractional) variable on which to branch.
        Possible values are:

        * `"mostFractional"`: choose the variable which is nearest to :math:`\\frac{1}{2}`
        * `"leastReliable"`: choose the fractional variable whose LLR value is closest to 0
    :param str selectionMethod: Method to determine the next node from the set of active nodes.
        Possible values:

        * `"dfs"`: Depth-first search
        * `"bbs"`: Best-bound search
        * `"mixed[-]/<a>/<b>/<c>/<d>"`: Mixed strategy. Uses depth-first search in general but
            jumps to the node with smallest lower bound every <a> iterations, but only if the
            duality gap at the current node is at least <d>. In the DFS phase, at most <c> RPC
            cut-search iterations are performed in the LP solver in each node. After a BBS jump,
            <b> is used instead.
    :param str childOrder: Determines the order in which newly created child branch-and-bound
        nodes are appended to the list of active nodes. Possible values are:

        * `"01"`: child with zero-fix is added first
        * `"10"`: child with one-fix is added first
        * `"llr"`: add first the node whose fix-value equals the hard-decision value of the fixed bit.
        * `"random"`: add in random order
    :param bool highSNR: Use optimizations for high SNR values.
    :param str name: Name of the decoder
    :param dict lpParams: Parameters for the LP decoder
    :param dict iterParams: Parameters for the iterative decoder
    """
    cdef:
        bint calcUb  # indicates whether to run the iterative decoder in the next iteration
        bint ubBB, highSNR, minDistance
        bytes childOrder
        object timer
        SelectionMethod selectionMethod
        BranchingRule branchRule
        public Decoder lbProvider, ubProvider
        int mixParam, maxRPCspecial, maxRPCnormal, maxRPCorig
        double mixGap, sentObjective, objBufLimOrig, cutoffOrig
        public int selectCnt
        Node root

    def __init__(self, code,
                 branchClass=MostFractional,
                 branchParams=None,
                 selectionMethod='dfs',
                 childOrder=b'01',
                 highSNR=False,
                 name='BranchAndCutDecoder',
                 lpClass=AdaptiveLPDecoder,
                 lpParams=None,
                 iterClass=IterativeDecoder,
                 iterParams=None):
        self.name = name
        if lpParams is None:
            lpParams = {}
        if iterParams is None:
            iterParams = {}
        if isinstance(lpClass, basestring):
            lpClass = persistence.classByName(lpClass)
        self.lbProvider = lpClass(code, **lpParams)
        if isinstance(iterClass, basestring):
            iterClass = persistence.classByName(iterClass)
        self.ubProvider = iterClass(code, **iterParams)
        self.highSNR = highSNR
        if branchParams is None:
            branchParams = {}
        if isinstance(branchClass, basestring):
            branchClass = eval(branchClass)
        self.branchRule = branchClass(code, self, **branchParams)
        if isinstance(childOrder, unicode):
            self.childOrder = childOrder.encode('utf8')
        else:
            self.childOrder = childOrder
        if selectionMethod.startswith('mixed'):
            self.selectionMethod = mixed
            if selectionMethod[5] == '-':
                self.ubBB = True
                selectionMethod = selectionMethod[7:]
            else:
                self.ubBB = False
                selectionMethod = selectionMethod[6:]
            a, b, c, d = selectionMethod.split("/")
            self.mixParam = int(a)
            self.maxRPCspecial = int(b)
            self.maxRPCnormal = int(c)
            self.mixGap = float(d)
            self.maxRPCorig = self.lbProvider.maxRPCrounds
            self.cutoffOrig = self.lbProvider.minCutoff
        elif selectionMethod == 'dfs':
            self.selectionMethod = dfs
        else:
            assert selectionMethod == "bbs", str(selectionMethod)
            self.selectionMethod = bbs
        self.timer = utils.Timer()
        self.objBufLimOrig = self.lbProvider.objBufLim
        Decoder.__init__(self, code, name=name)


    optimizedOptions=dict(name='B&C[mixed-/30/100/5/2;llr;cut.2;M-100;iter100-o2]',
                          selectionMethod='mixed-/30/100/5/2', childOrder=b'llr',
                          lpParams=dict(removeInactive=100, keepCuts=True,
                                        maxRPCrounds=-1, minCutoff=.2),
                          iterParams=dict(iterations=100, reencodeOrder=2,
                                          reencodeIfCodeword=False))

    def setStats(self, stats):
        for item in 'nodes', 'prBd1', 'prBd2', 'prInf', 'prBranch', 'prOpt', 'termEx', 'termGap', 'lpTime', \
                    'iterTime', 'maxDepth', 'branchTime', 'initUbOpt':
            if item not in stats:
                stats[item] = 0
        if 'lpStats' in stats:
            self.lbProvider.setStats(stats['lpStats'])
            del stats['lpStats']
        else:
            self.lbProvider.setStats(dict())
        if 'iterStats' in stats:
            self.ubProvider.setStats(stats['iterStats'])
            del stats['iterStats']
        else:
            self.ubProvider.setStats(dict())
        Decoder.setStats(self, stats)


    def stats(self):
        stats = self._stats.copy()
        stats['lpStats'] = self.lbProvider.stats().copy()
        stats['iterStats'] = self.ubProvider.stats().copy()
        return stats

    cpdef setLLRs(self, double[::1] llrs, np.int_t[::1] sent=None):
        cdef int i
        self.ubProvider.setLLRs(llrs, sent)
        if sent is not None:
            self.sentObjective = np.dot(sent, llrs)
            for i in range(sent.size):
                self.solution[i] = sent[i]
        else:
            self.sentObjective = -INFINITY
        if self.highSNR:
            self.ubProvider.foundCodeword = self.ubProvider.mlCertificate = False
        else:
            self.timer.start()
            self.ubProvider.solve()
            self._stats['iterTime'] += self.timer.stop()
            if self.ubProvider.foundCodeword:
                self.lbProvider.hint = np.asarray(self.ubProvider.solution).astype(np.int)
                # codeword will be used in first iteration of main algorithm; no need to copy it
                # here
        self.lbProvider.setLLRs(llrs, sent)
        Decoder.setLLRs(self, llrs)


    cpdef fix(self, int index, int value):
        self.lbProvider.fix(index, value)
        self.ubProvider.fix(index, value)


    cpdef release(self, int index):
        self.lbProvider.release(index)
        self.ubProvider.release(index)


    cpdef fixed(self, int index):
        return self.lbProvider.fixed(index)


    cpdef solve(self, double lb=-INFINITY, double ub=INFINITY):
        cdef:
            Node node, newNode0, newNode1, newNode
            list activeNodes = []
            int iteration = 0, branchIndex
            str depthStr
            double totalIters = 0
            bint initOpt = True
        ub = 0 if self.sentObjective == -INFINITY else self.sentObjective
        self.branchRule.reset()
        #  ensure there are no leftover fixes from previous decodings
        self.foundCodeword = self.mlCertificate = True
        self.root = node = Node()
        self.calcUb = True
        self.selectCnt = 0 #  parameter used for the mixed node selection strategy
        self._stats['nodes'] += 1
        if self.selectionMethod == mixed:
            self.lbProvider.maxRPCrounds = self.maxRPCspecial

        while True:
            iteration += 1
            if node.depth > self._stats['maxDepth']:
                self._stats['maxDepth'] = node.depth
            if iteration % 10 == 0:
                logger.debug('{}/{}, c {}, it {}, lp {:6f}, heu {:6f} bra {:6f}'.format(
                    self.root.lb, ub, self.lbProvider.model.NumConstrs,
                    iteration, self._stats["lpTime"], self._stats['iterTime'], self._stats['branchTime']))
            # upper bound calculation
            if iteration > 1 and self.calcUb: # for first iteration this was done in setLLR
                self.timer.start()
                self.ubProvider.solve()
                self._stats["iterTime"] += self.timer.stop()
            if self.ubProvider.foundCodeword and self.ubProvider.objectiveValue < ub:
                self.solution[:] = self.ubProvider.solution[:]
                ub = self.ubProvider.objectiveValue
                if iteration > 1:
                    initOpt = False
                if ub < self.sentObjective  - 1e-5:
                    self.mlCertificate = False
                    break

            # lower bound calculation
            if (iteration == 1 or self.calcUb) and self.ubProvider.foundCodeword:
                # self.lbProvider.hint = np.asarray(self.ubProvider.solution).astype(np.int)
                pass #TODO hint not used
            else:
                self.lbProvider.hint = None
            if node.depth == 0:
                # special root node treatment
                self.lbProvider.maxRPCrounds = -1
                self.lbProvider.objBufLim = 0.01
                self.lbProvider.minCutoff = 1e-5
            rounds = self.lbProvider._stats['rpcRounds']
            totalIters -= self.lbProvider._stats['simplexIters']

            self.timer.start()
            self.lbProvider.solve(node.lb, ub)
            node.lpObj = self.lbProvider.objectiveValue
            self._stats['lpTime'] += self.timer.stop()
            if self.lbProvider.status == Decoder.UPPER_BOUND_HIT:
                node.lb = INFINITY
                self._stats['prBd2'] += 1
            elif self.lbProvider.status == Decoder.INFEASIBLE:
                node.lb = INFINITY
                self._stats['prInf'] += 1
            elif self.lbProvider.objectiveValue > node.lb:
                node.lb = self.lbProvider.objectiveValue
            self.branchRule.callback(node)
            totalIters += self.lbProvider._stats['simplexIters']
            if node.depth == 0:
                self.lbProvider.objBufLim = self.objBufLimOrig
                self.lbProvider.maxRPCrounds = self.maxRPCorig
                self.lbProvider.minCutoff = self.cutoffOrig
                self.branchRule.rootCallback(self.lbProvider._stats['rpcRounds'] - rounds,
                                             self.lbProvider._stats['simplexIters'] - totalIters)
            # pruning or branching
            if self.lbProvider.foundCodeword:
                # solution is integral
                if self.lbProvider.objectiveValue < ub:
                    self.solution[:] = self.lbProvider.solution[:]
                    ub = self.lbProvider.objectiveValue
                    self._stats['prOpt'] += 1
                    initOpt = False
                    if ub < self.sentObjective - 1e-5:
                        self.mlCertificate = False
                        break
            elif node.lb < ub-1e-6:
                # branch
                self.timer.start()
                self.branchRule.computeBranchIndex(node, ub, self.lbProvider.solution.copy())
                self._stats['branchTime'] += self.timer.stop()
                if self.branchRule.canPrune or node.lb >= ub - 1e-6:
                    print('prune')
                    self._stats['prBranch'] += 1
                else:
                    branchIndex = self.branchRule.index
                    if branchIndex < 0:
                        print('BAA', branchIndex)
                        print([i for i in range(self.code.blocklength) if self.fixed(i)])
                        print(np.asarray(self.lbProvider.solution))
                        print(np.around(np.dot(self.code.parityCheckMatrix, self.lbProvider.solution), 6) % 2)
                        print(self.lbProvider.solution in self.code)
                        print(np.allclose(np.mod(self.lbProvider.solution, 1), 0))
                        print(np.mod(self.lbProvider.solution, 1))
                        print(gfqla.inKernel(self.code.parityCheckMatrix, np.rint(self.lbProvider.solution).astype(np.int)))
                        raise RuntimeError()
                    activeNodes.extend(node.branch(branchIndex, self.childOrder, self, ub))
            if node.parent is not None:
                node.parent.updateBound(node.lb, node.branchValue)
                if self.root.lb >= ub - 1e-6:
                    self._stats["termGap"] += 1
                    break
            if len(activeNodes) == 0:
                self._stats["termEx"] += 1
                break
            newNode = self.selectNode(activeNodes, node, ub)
            move(self.lbProvider, self.ubProvider, node, newNode)
            node = newNode
        if self.selectionMethod == mixed:
            self.lbProvider.maxRPCrounds = self.maxRPCorig
        self.objectiveValue = ub
        if initOpt:
            self._stats['initUbOpt'] += 1
        for i in range(self.code.blocklength):
            self.lbProvider.release(i)
            self.ubProvider.release(i)


    def minimumDistance(self, randomized=True, cyclic=False):
        """Compute the minimum distance of the code."""
        # switch to min distance computation mode
        self.ubProvider.excludeZero = self.minDistance = True
        llrs = np.ones(self.code.blocklength, dtype=np.double)

        if randomized:
            # add small random values to the llrs, to enforce a unique solution
            delta = 0.001
            epsilon = delta/self.code.blocklength
            np.random.seed(239847)
            llrs += epsilon*np.random.random_sample(self.code.blocklength)
        else:
            delta = 1e-5
        for i in range(cyclic): # fix bits to one for cyclic codes (or other symmetries)
            self.fix(i, 1)
        self.setLLRs(llrs)
        self.selectCnt = 1
        self.root = node = Node()
        self.root.lb = 1
        activeNodes = []
        self.branchRule.reset()
        ub = INFINITY
        self._stats['nodes'] += 1
        for iteration in itertools.count(start=1):
            # statistic collection and debug output
            depthStr = str(node.depth)
            if iteration % 10 == 0:
                logger.info('MD {}/{}, d {}, n {}, it {}, lp {}, heu {} bra {}'.format(
                    self.root.lb,ub, node.depth,len(activeNodes), iteration,
                    self._stats["lpTime"], self._stats['iterTime'], self._stats['branchTime']))
            pruned = False # store if current node can be pruned
            if node.lb >= ub-1+delta:
                node.lb = INFINITY
                pruned = True
            if not pruned:
                # upper bound calculation

                if iteration > 1 and self.calcUb: # for first iteration this was done in setLLR
                    self.timer.start()
                    self.ubProvider.solve()
                    self._stats['iterTime'] += self.timer.stop()

                if self.ubProvider.foundCodeword and self.ubProvider.objectiveValue < ub:
                    self.solution[:] = self.ubProvider.solution[:]
                    ub = self.ubProvider.objectiveValue
                # lower bound calculation
                self.timer.start()

                if (iteration == 1 or self.calcUb) and self.ubProvider.foundCodeword:
                    self.lbProvider.hint = np.asarray(self.ubProvider.solution).astype(np.int)
                else:
                    self.lbProvider.hint = None
                self.lbProvider.solve(-INFINITY, ub - 1 + delta)
                node.lpObj = self.lbProvider.objectiveValue
                self._stats['lpTime'] += self.timer.stop()
                if self.lbProvider.status == Decoder.UPPER_BOUND_HIT:
                    node.lb = INFINITY
                    self._stats['prBd2'] += 1
                elif self.lbProvider.status == Decoder.INFEASIBLE:
                    node.lb = INFINITY
                    self._stats['prInf'] += 1
                elif self.lbProvider.objectiveValue > node.lb:
                    node.lb = self.lbProvider.objectiveValue
                self.branchRule.callback(node)
                if node.lb == INFINITY:
                    self._stats['prInf'] += 1
                elif self.lbProvider.foundCodeword and self.lbProvider.objectiveValue > .5:
                    # solution is integral
                    if self.lbProvider.objectiveValue < ub:
                        self.solution[:] = self.lbProvider.solution[:]
                        print('new candidate from LP with weight {}'.format(
                            self.lbProvider.objectiveValue))
                        print(np.asarray(self.solution))
                        ub = self.lbProvider.objectiveValue
                        logger.debug('ub improved to {}'.format(ub))
                        self._stats['prOpt'] += 1
                elif node.lb < ub-1+delta:
                    # branch
                    self.timer.start()
                    self.branchRule.computeBranchIndex(node, ub, self.lbProvider.solution.copy())
                    self._stats['branchTime'] += self.timer.stop()
                    if self.branchRule.canPrune or node.lb >= ub - 1 + delta:
                        node.lb = INFINITY
                        self._stats['prBranch'] += 1
                    else:
                        branchIndex = self.branchRule.index
                        if branchIndex == -1:
                            node.lb = INFINITY
                            print('********** PRUNE 000000 ***************')
                        else:
                            activeNodes.extend(node.branch(branchIndex, self.childOrder, self, ub))
                else:
                    self._stats["prBd2"] += 1
            if node.parent is not None:
                node.parent.updateBound(node.lb, node.branchValue)
                if self.root.lb >= ub - 1 + delta:
                    self._stats["termGap"] += 1
                    break
            if len(activeNodes) == 0:
                self._stats["termEx"] += 1
                break
            newNode = self.selectNode(activeNodes, node, ub)
            move(self.lbProvider, self.ubProvider, node, newNode)
            node = newNode

        assert self.solution in self.code
        self.objectiveValue = np.rint(ub)
        print('Minimum distance of {} computed successfully'.format(self.code))
        print('Minimum codeword is:')
        print(np.asarray(self.solution))
        print('MininumDistance is: {}'.format(self.objectiveValue))
        # restore normal (decoding) mode
        self.ubProvider.excludeZero = self.minDistance = False
        return self.objectiveValue

    cdef Node popMinNode(self, list activeNodes):
        cdef int i, minIndex = -1
        cdef double minValue = INFINITY
        for i in range(len(activeNodes)):
            if activeNodes[i].lb < minValue:
                minIndex = i
                minValue = activeNodes[i].lb
        return activeNodes.pop(minIndex)


    cdef Node selectNode(self, list activeNodes, Node currentNode, double ub):
        if self.selectionMethod == mixed:
            if (self.selectCnt >= self.mixParam or (self.minDistance and self.root.lb == 1)) and (ub - currentNode.lb) > self.mixGap:
                # best bound step
                newNode = self.popMinNode(activeNodes)
                self.selectCnt = 1
                self.lbProvider.maxRPCrounds = self.maxRPCspecial
                # self.lbProvider.objBufLim = self.objBufLimOrig / 3
                # self.lbProvider.minCutoff = self.cutoffOrig / 3
                if self.ubBB:
                    self.calcUb = True
                newNode.special = True
                return newNode
            else:
                newNode = activeNodes.pop()
                self.lbProvider.maxRPCrounds = self.maxRPCnormal
                # self.lbProvider.objBufLim = self.objBufLimOrig
                # self.lbProvider.minCutoff = self.cutoffOrig
                self.selectCnt += 1
                if self.ubBB:
                    self.calcUb = False

                return newNode
        elif self.selectionMethod == dfs:
            return activeNodes.pop()
        elif self.selectionMethod == bbs:
            return self.popMinNode(activeNodes)

    def params(self):
        if self.selectionMethod == mixed:
            method = "mixed{}/{}/{}/{}/{}".format('-' if self.ubBB else "",
                                                   self.mixParam,
                                                   self.maxRPCspecial,
                                                   self.maxRPCnormal,
                                                   self.mixGap)
        else:
            selectionMethodNames = { dfs: "dfs", bbs: "bbs"}
            method = selectionMethodNames[self.selectionMethod]
        parms = OrderedDict()
        parms['branchClass'] = type(self.branchRule).__name__
        parms['branchParams'] = self.branchRule.params()
        parms['selectionMethod'] = method
        if self.childOrder != b'01':
            parms['childOrder'] = self.childOrder.decode('utf8')
        if type(self.lbProvider) is not AdaptiveLPDecoder:
            parms['lpClass'] = type(self.lbProvider).__name__
        parms['lpParams'] = self.lbProvider.params()
        if type(self.ubProvider) is not IterativeDecoder:
            parms['iterClass'] = type(self.ubProvider).__name__
        parms['iterParams'] = self.ubProvider.params()
        if self.highSNR:
            parms['highSNR'] = True
        parms['name'] = self.name
        return parms
