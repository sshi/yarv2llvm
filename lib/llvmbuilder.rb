#!/bin/ruby
#
#  Abstruct layer of llvmruby
#

module YARV2LLVM

class LLVMBuilder
  include LLVM
  include RubyHelpers

  def initialize
    @module = LLVM::Module.new('yarv2llvm')
    @externed_function = {}
    ExecutionEngine.get(@module)
  end

  def make_stub(name, rett, argt, orgfunc)
    sname = "__stub_" + name
    stype = Type.function(VALUE, [VALUE] * argt.size)
    @stubfunc = @module.get_or_insert_function(sname, stype)
    eb = @stubfunc.create_block
    b = eb.builder
    argv = []
    context = Context.new([], self, false)

    argt.each_with_index do |ar, n|
      v = ar.type.from_value(@stubfunc.arguments[n], b, context)
      argv.push v
    end

    ret = b.call(orgfunc, *argv)

    x = rett.type.to_value(ret, b, context)
    b.return(x)

    MethodDefinition::RubyMethodStub[name] = {
      :sname => sname,
      :stub => @stubfunc,
      :argt => argt,
      :type => stype}
  end

  def define_function(name, rett, argt, is_mkstub)
    argtl = argt.map {|a| a.type.llvm}
    rettl = rett.type.llvm
    type = Type.function(rettl, argtl)
    @func = @module.get_or_insert_function(name, type)
    
    if is_mkstub then
      @stub = make_stub(name, rett, argt, @func)
    end

    MethodDefinition::RubyMethod[name.to_sym][:func] = @func

    eb = @func.create_block
    eb.builder
  end

  def get_or_insert_function(name, type)
    ns = name.to_s
    @module.get_or_insert_function(ns, type)
  end

  def arguments
    @func.arguments
  end

  def create_block
    @func.create_block
  end

  def external_function(name, type)
    if rc = @externed_function[name] then
      rc
    else
      @externed_function[name] = @module.external_function(name, type)
    end
  end

  def optimize
    bitout =  Tempfile.new('bit')
    @module.write_bitcode("#{bitout.path}")
    File.popen("/usr/local/bin/opt -O3 -f #{bitout.path}") {|fp|
      @module = LLVM::Module.read_bitcode(fp.read)
    }
    MethodDefinition::RubyMethodStub.each do |nm, val|
      val[:stub] = @module.get_or_insert_function(val[:sname], val[:type])
    end
  end

  def disassemble
    # @module.write_bitcode("yarv.bc")
    p @module
  end
end

end # module YARV2LLVM