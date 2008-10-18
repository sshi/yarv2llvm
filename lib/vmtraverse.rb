#!/bin/ruby 
#
#  Traverse YARV instruction array
#

module YARV2LLVM
class Context
  def initialize(local, builder)
    @local_vars = local
    @rc = nil
    @org = nil
    @blocks = {}
    @block_value = {}
    @last_stack_value = nil
    @curln = nil
    @builder = builder
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks
  attr_accessor :last_stack_value
  attr_accessor :curln
  attr_accessor :block_value
  attr :builder
end

class YarvVisitor
  def initialize(iseq)
    @iseq = iseq
  end

  def run
    @iseq.traverse_code([nil, nil, nil]) do |code, info|
      local = []
      visit_block_start(code, nil, local, nil, info)
      curln = nil
      code.lblock_list.each do |ln|
        visit_local_block_start(code, ln, local, ln, info)

        curln = ln
        code.lblock[ln].each do |ins|
          opname = ins[0].to_s
          send(("visit_" + opname).to_sym, code, ins, local, curln, info)

          case ins[0]
          when :branchif, :branchunless, :jump
            curln = (curln.to_s + "_1").to_sym
          end
        end
#        ln = curln
        visit_local_block_end(code, ln, local, ln, info)
      end

      visit_block_end(code, nil, local, nil, info)
    end
  end

  def method_missing(name, code, ins, local, ln, info)
    visit_default(code, ins, local, ln, info)
  end
end

class YarvTranslator<YarvVisitor
  include LLVM
  include RubyHelpers

  def initialize(iseq)
    super(iseq)
    @builder = LLVMBuilder.new
    @expstack = []
    @rescode = lambda {|b, context| context}
    @code_gen = {}
    @jump_hist = {}
    @prev_label = nil
    @is_live = nil
  end

  def run
    super
    @code_gen.each do |fname, gen|
      gen.call
    end
#    @builder.optimize
    @builder.disassemble
    
  end
  
  def get_or_create_block(ln, b, context)
    if context.blocks[ln] then
      context.blocks[ln]
    else
      context.blocks[ln] = context.builder.create_block
    end
  end
  
  def visit_local_block_start(code, ins, local, ln, info)
    oldrescode = @rescode
    live =  @is_live

    @is_live = nil
    if live and @expstack.size > 0 then
      valexp = @expstack.pop
    end

    @jump_hist[ln] ||= []
    @jump_hist[ln].push @prev_label
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      blk = get_or_create_block(ln, b, context)
      if live then
        if valexp then
          bval = [valexp[0], valexp[1].call(b, context).rc]
          context.block_value[context.curln] = bval
        end
        b.br(blk)
      end
      context.curln = ln
      b.set_insert_point(blk)
      context
    }

    if valexp then
      n = 0
      v2 = nil
      commer_label = @jump_hist[ln]
      while n < commer_label.size - 1 do
        if v2 = @expstack[@expstack.size - n - 1] then
          valexp[0].add_same_type(v2[0])
          v2[0].add_same_type(valexp[0])
        end
        n += 1
      end
      @expstack.push [valexp[0],
        lambda {|b, context|
          if ln then
            rc = b.phi(context.block_value[commer_label[0]][0].type.llvm)
            
            commer_label.reverse.each do |lab|
              rc.add_incoming(context.block_value[lab][1], 
                              context.blocks[lab])
            end

            context.rc = rc
          end
          context
        }]
    end
  end
  
  def visit_local_block_end(code, ins, local, ln, info)
    # This if-block inform next calling visit_local_block_start
    # must generate jump statement.
    # You may worry generate wrong jump statement but return
    # statement. But in this situration, visit_local_block_start
    # don't call before visit_block_start call.
    if @is_live == nil then
      @is_live = true
      @prev_label = ln
    end
    # p @expstack.map {|n| n[1]}
  end
  
  def visit_block_start(code, ins, local, ln, info)
    ([nil, :self] + code.header['locals'].reverse).each_with_index do |n, i|
      local[i] = {:name => n, :type => RubyType.new(nil, n), :area => nil}
    end
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyCMthhod for recursive call
    if info[1] then
      if MethodDefinition::RubyMethod[info[1]] then
        raise "#{info[1]} is already defined"
      else
        argt = []
        1.upto(numarg) do |n|
          argt[n - 1] = local[-n][:type]
        end
        MethodDefinition::RubyMethod[info[1]]= {
          :argtype => argt,
          :rettype => RubyType.new(nil, :ret)
        }
      end
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context.local_vars.each_with_index {|vars, n|
        if vars[:type].type then
          lv = b.alloca(vars[:type].type.llvm, 1)
          vars[:area] = lv
        else
          vars[:area] = nil
        end
      }

      # Copy argument in reg. to allocated area
      arg = context.builder.arguments
      lvars = context.local_vars
      1.upto(numarg) do |n|
        b.store(arg[n - 1], lvars[-n][:area])
      end

      context
    }
  end
  
  def visit_block_end(code, ins, local, ln, info)
    RubyType.resolve

    numarg = code.header['misc'][:arg_size]
=begin
    # write function prototype
    if info[1] then
      print "#{info[1]} :("
      1.upto(numarg) do |n|
        print "#{local[-n][:type].inspect2}, "
      end
      print ") -> #{@expstack.last[0].inspect2}\n"
    end
=end

    argtype = []
    1.upto(numarg) do |n|
      argtype[n - 1] = local[-n][:type]
    end

    if @expstack.last and info[1] then
      retexp = @expstack.pop
      code = @rescode
      @code_gen[info[1]] = lambda {
        pppp "define #{info[1]}"
        pppp @expstack
      
        b = @builder.define_function(info[1].to_s, 
                                   retexp[0], argtype)
        context = code.call(b, Context.new(local, @builder))
        b.return(retexp[1].call(b, context).rc)

        pppp "ret type #{retexp[0].type}"
        pppp "end"
      }
    end

    @expstack = []
    @rescode = lambda {|b, context| context}
  end
  
  def visit_default(code, ins, local, ln, info)
#    pppp ins
  end
  
  def visit_putnil(code, ins, local, ln, info)
    # Nil is not support yet.
=begin
    @expstack.push [RubyType.typeof(nil), 
      lambda {|b, context| 
        nil
      }]
=end
  end

  def visit_putobject(code, ins, local, ln, info)
    p1 = ins[1]
    @expstack.push [RubyType.typeof(p1), 
      lambda {|b, context| 
        pppp p1
        context.rc = p1.llvm 
        context.org = p1
        context
      }]
  end

  def visit_newarray(code, ins, local, ln, info)
    nele = ins[1]
    inits = []
    nele.times {|n|
      v = @expstack.pop
      inits.push v
    }
    inits.reverse!
    @expstack.push [RubyType.new(ArrayType.new(nil)),
      lambda {|b, context|
        if nele == 0 then
          ftype = Type.function(VALUE, [])
          func = context.builder.external_function('rb_ary_new', ftype)
          rc = b.call(func)
          context.rc = rc
          pppp "newarray END"
        else
          # TODO: eval inits and call rb_ary_new4
          raise "Initialized array not implemented"
        end
        context
      }]
  end
  
  def visit_getlocal(code, ins, local, ln, info)
    p1 = ins[1]
    type = local[p1][:type]
    @expstack.push [type,
      lambda {|b, context|
        context.rc = b.load(context.local_vars[p1][:area])
        context.org = local[p1][:name]
        context
      }]
  end
  
  def visit_setlocal(code, ins, local, ln, info)
    p1 = ins[1]
    dsttype = local[p1][:type]
    
    src = @expstack.pop
    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_type(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setlocal start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      context.last_stack_value = context.rc
      lvar = context.local_vars[p1]
      context.rc = b.store(context.rc, lvar[:area])
      context.org = lvar[:name]
      pppp "Setlocal end"
      context
    }
  end

  def visit_send(code, ins, local, ln, info)
    p1 = ins[1]
    if funcinfo = MethodDefinition::SystemMethod[p1] then
      funcinfo[:args].downto(1) do |n|
        @expstack.pop
      end
      return
    end

    if funcinfo = MethodDefinition::InlineMethod[p1] then
      instance_eval &funcinfo[:inline_proc]
    end

    if funcinfo = MethodDefinition::CMethod[p1] then
      rettype = RubyType.new(funcinfo[:rettype])
      argtype = funcinfo[:argtype].map {|ts| RubyType.new(ts)}
      cname = funcinfo[:cname]
      
      if argtype.size == ins[2] then
        argtype2 = argtype.map {|tc| tc.type.llvm}
        ftype = Type.function(rettype.type.llvm, argtype2)
        func = @builder.external_function(cname, ftype)

        p = []
        0.upto(ins[2] - 1) do |n|
          p[n] = @expstack.pop
          if p[n][0].type and p[n][0].type != argtype[n].type then
            raise "arg error"
          else
            p[n][0].add_same_type argtype[n]
            argtype[n].add_same_type p[n][0]
          end
        end
          
        @expstack.push [rettype,
          lambda {|b, context|
            args = []
            p.each do |pe|
              args.push pe[1].call(b, context).rc
            end
            # p cname
            # print func
            context.rc = b.call(func, *args)
            context
          }
        ]
        return
      end
    end

    if minfo = MethodDefinition::RubyMethod[p1] then
      pppp "RubyMethod called #{p1.inspect}"
      para = []
      0.upto(ins[2] - 1) do |n|
        v = @expstack.pop

        v[0].add_same_type(minfo[:argtype][n])
        minfo[:argtype][n].add_same_type(v[0])

        para[n] = v
      end
      @expstack.push [minfo[:rettype],
        lambda {|b, context|
          minfo = MethodDefinition::RubyMethod[p1]
          func = minfo[:func]
          args = []
          para.each do |pe|
            args.push pe[1].call(b, context).rc
          end
          context.rc = b.call(func, *args)
          context
        }]
      return
    end
  end

  def visit_branchunless(code, ins, local, ln, info)
    s1 = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
    @is_live = false
    iflab = nil
    @jump_hist[lab] ||= []
    @jump_hist[lab].push (ln.to_s + "_1").to_sym
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      eblock = context.builder.create_block
      iflab = context.curln
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks[context.curln] = eblock
      tblock = get_or_create_block(lab, b, context)
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      b.cond_br(s1[1].call(b, context).rc, eblock, tblock)
      b.set_insert_point(eblock)

      context
    }
    if valexp then
      @expstack.push [valexp[0], 
        lambda {|b, context| 
          context.rc = context.block_value[iflab][1]
          context}]

    end
  end

  def visit_branchif(code, ins, local, ln, info)
    s1 = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
#    @is_live = false
    iflab = nil
    @jump_hist[lab] ||= []
    @jump_hist[lab].push (ln.to_s + "_1").to_sym
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      tblock = get_or_create_block(lab, b, context)
      iflab = context.curln

      eblock = context.builder.create_block
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks[context.curln] = eblock
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      b.cond_br(s1[1].call(b, context).rc, tblock, eblock)
      b.set_insert_point(eblock)

      context
    }
    if valexp then
      @expstack.push [valexp[0], 
        lambda {|b, context| 
          context.rc = context.block_value[iflab][1]
          context}]

    end
  end

  def visit_jump(code, ins, local, ln, info)
    lab = ins[1]
    fmlab = nil
    oldrescode = @rescode
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
    @is_live = false
    @jump_hist[lab] ||= []
    @jump_hist[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      jblock = get_or_create_block(lab, b, context)
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        fmlab = context.curln
        context.block_value[fmlab] = bval
      end
      b.br(jblock)

      context
    }
    if valexp then
      @expstack.push [valexp[0],
        lambda {|b, context| 
          context.rc = context.block_value[fmlab][1]
          context
        }]
    end
  end

  def visit_dup(code, ins, local, ln, info)
    s1 = @expstack.pop
    @expstack.push [s1[0],
      lambda {|b, context|
        context.rc = context.last_stack_value
        context
      }]
    @expstack.push s1
  end
  
  def check_same_type_2arg_static(p1, p2)
    p1[0].add_same_type(p2[0])
    p2[0].add_same_type(p1[0])
  end
  
  def check_same_type_2arg_gencode(b, context, p1, p2)
    if p1[0].type == nil then
      if p2[0].type == nil then
        print "ambious type #{p2[1].call(b, context).org}\n"
      else
        p1[0].type = p2[0].type
      end
    else
      if p2[0].type and p1[0].type != p2[0].type then
        print "diff type #{p1[1].call(b, context).org}\n"
      else
        p2[0].type = p1[0].type
      end
    end
  end

  def gen_common_opt_2arg(b, context, s1, s2)
    check_same_type_2arg_gencode(b, context, s1, s2)
    context = s1[1].call(b, context)
    s1val = context.rc
    #        pppp s1[0]
    context = s2[1].call(b, context)
    s2val = context.rc

    [s1val, s2val, context]
  end

  def visit_opt_plus(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    #    p @expstack
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.add(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_minus(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.sub(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_mult(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.mul(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_div(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fdiv(s1val, s2val)
        when Type::Int32TY
          context.rc = b.sdiv(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_eq(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ueq(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_eq(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_lt(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ult(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_slt(s1val, s2val)
        end
        context
      }
    ]
  end
  
  def visit_opt_gt(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ugt(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_sgt(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_aref(code, ins, local, ln, info)
    idx = @expstack.pop
    arr = @expstack.pop
    fix = RubyType.fixnum
    idx[0].add_same_type(fix)
    fix.add_same_type(idx[0])
    RubyType.resolve
    if arr[0].type == nil then
      arr[0].type = ArrayType.new(nil)
    end
    
    @expstack.push [arr[0].type.element_type, 
      lambda {|b, context|
        pppp "aref start"
        if arr[0].type.is_a?(ArrayType) then
          context = idx[1].call(b, context)
          idxp = context.rc
          context = arr[1].call(b, context)
          arrp = context.rc
          ftype = Type.function(VALUE, [VALUE, Type::Int32Ty])
          func = context.builder.external_function('rb_ary_entry', ftype)
          context.rc = b.call(func, arrp, idxp)
          context
        else
          # Todo: Hash table?
          raise "Not impremented"
        end
      }
    ]
  end
end

def compile_file(fn)
  is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is)
end

def compile(str)
  is = RubyVM::InstructionSequence.compile( str, "<llvm2ruby>", 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is)
end

def compcommon(is)
  iseq = VMLib::InstSeqTree.new(nil, is)
  pppp iseq.to_a
  YarvTranslator.new(iseq).run
  MethodDefinition::RubyMethodStub.each do |key, m|
    name = key
    n = 0
    if m[:argt] == [] then
      args = ""
      args2 = ""
    else
      args = m[:argt].map {|x|  n += 1; "p" + n.to_s}.join(',')
      args2 = ', ' + args
    end
    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    pppp df
    eval df, TOPLEVEL_BINDING
  end
end

module_function :compile_file
module_function :compile
module_function :compcommon
end
