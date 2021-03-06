/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (c) 1999-2017 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/ddmd/irstate.d, _irstate.d)
 * Documentation: https://dlang.org/phobos/ddmd_irstate.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/ddmd/irstate.d
 */

module ddmd.irstate;

import ddmd.root.array;

import ddmd.arraytypes;
import ddmd.backend.type;
import ddmd.dmodule;
import ddmd.dsymbol;
import ddmd.func;
import ddmd.identifier;
import ddmd.statement;
import ddmd.globals;
import ddmd.mtype;

import ddmd.backend.cc;
import ddmd.backend.el;

/****************************************
 * Our label symbol, with vector to keep track of forward references.
 */

struct Label
{
    block *lblock;      // The block to which the label is defined.
    block *fwdrefs;     // The first use of the label before it is defined.
}

/***********************************************************
 */
struct IRState
{
    IRState* prev;
    Statement statement;
    Module m;                       // module
    private FuncDeclaration symbol; // function that code is being generate for
    Identifier ident;
    Symbol* shidden;                // hidden parameter to function
    Symbol* sthis;                  // 'this' parameter to function (member and nested)
    Symbol* sclosure;               // pointer to closure instance
    Blockx* blx;
    Dsymbols* deferToObj;           // array of Dsymbol's to run toObjFile(bool multiobj) on later
    elem* ehidden;                  // transmit hidden pointer to CallExp::toElem()
    Symbol* startaddress;
    Array!(elem*)* varsInScope;     // variables that are in scope that will need destruction later
    Label*[void*]* labels;          // table of labels used/declared in function
    bool mayThrow;                  // the expression being evaluated may throw

    block* breakBlock;
    block* contBlock;
    block* switchBlock;
    block* defaultBlock;
    block* finallyBlock;

    this(IRState* irs, Statement s)
    {
        prev = irs;
        statement = s;
        if (irs)
        {
            m = irs.m;
            shidden = irs.shidden;
            sclosure = irs.sclosure;
            sthis = irs.sthis;
            blx = irs.blx;
            deferToObj = irs.deferToObj;
            varsInScope = irs.varsInScope;
            labels = irs.labels;
            mayThrow = irs.mayThrow;
        }
    }

    this(Module m, FuncDeclaration fd, Array!(elem*)* varsInScope, Dsymbols* deferToObj, Label*[void*]* labels)
    {
        this.m = m;
        this.symbol = fd;
        this.varsInScope = varsInScope;
        this.deferToObj = deferToObj;
        this.labels = labels;
        mayThrow = global.params.useExceptions &&
                !(fd && fd.eh_none);
    }

    /****
     * Access labels AA from C++ code.
     * Params:
     *  s = key
     * Returns:
     *  pointer to value if it's there, null if not
     */
    Label** lookupLabel(Statement s)
    {
        return cast(void*)s in *labels;
    }

    /****
     * Access labels AA from C++ code.
     * Params:
     *  s = key
     *  label = value
     */
    void insertLabel(Statement s, Label* label)
    {
        (*labels)[cast(void*)s] = label;
    }

    block* getBreakBlock(Identifier ident)
    {
        IRState* bc;
        if (ident)
        {
            Statement related = null;
            block* ret = null;
            for (bc = &this; bc; bc = bc.prev)
            {
                // The label for a breakBlock may actually be some levels up (e.g.
                // on a try/finally wrapping a loop). We'll see if this breakBlock
                // is the one to return once we reach that outer statement (which
                // in many cases will be this same statement).
                if (bc.breakBlock)
                {
                    related = bc.statement.getRelatedLabeled();
                    ret = bc.breakBlock;
                }
                if (bc.statement == related && bc.prev.ident == ident)
                    return ret;
            }
        }
        else
        {
            for (bc = &this; bc; bc = bc.prev)
            {
                if (bc.breakBlock)
                    return bc.breakBlock;
            }
        }
        return null;
    }

    block* getContBlock(Identifier ident)
    {
        IRState* bc;
        if (ident)
        {
            block* ret = null;
            for (bc = &this; bc; bc = bc.prev)
            {
                // The label for a contBlock may actually be some levels up (e.g.
                // on a try/finally wrapping a loop). We'll see if this contBlock
                // is the one to return once we reach that outer statement (which
                // in many cases will be this same statement).
                if (bc.contBlock)
                {
                    ret = bc.contBlock;
                }
                if (bc.prev && bc.prev.ident == ident)
                    return ret;
            }
        }
        else
        {
            for (bc = &this; bc; bc = bc.prev)
            {
                if (bc.contBlock)
                    return bc.contBlock;
            }
        }
        return null;
    }

    block* getSwitchBlock()
    {
        IRState* bc;
        for (bc = &this; bc; bc = bc.prev)
        {
            if (bc.switchBlock)
                return bc.switchBlock;
        }
        return null;
    }

    block* getDefaultBlock()
    {
        IRState* bc;
        for (bc = &this; bc; bc = bc.prev)
        {
            if (bc.defaultBlock)
                return bc.defaultBlock;
        }
        return null;
    }

    block* getFinallyBlock()
    {
        IRState* bc;
        for (bc = &this; bc; bc = bc.prev)
        {
            if (bc.finallyBlock)
                return bc.finallyBlock;
        }
        return null;
    }

    FuncDeclaration getFunc()
    {
        for (auto bc = &this; 1; bc = bc.prev)
        {
            if (!bc.prev)
                return bc.symbol;
        }
    }

    /**********************
     * Returns:
     *    true if do array bounds checking for the current function
     */
    bool arrayBoundsCheck()
    {
        bool result;
        final switch (global.params.useArrayBounds)
        {
        case CHECKENABLE.off:
            result = false;
            break;
        case CHECKENABLE.on:
            result = true;
            break;
        case CHECKENABLE.safeonly:
            {
                result = false;
                FuncDeclaration fd = getFunc();
                if (fd)
                {
                    Type t = fd.type;
                    if (t.ty == Tfunction && (cast(TypeFunction)t).trust == TRUSTsafe)
                        result = true;
                }
                break;
            }
        case CHECKENABLE._default:
            assert(0);
        }
        return result;
    }

    /****************************
     * Returns:
     *  true if in a nothrow section of code
     */
    bool isNothrow()
    {
        return !mayThrow;
    }
}
