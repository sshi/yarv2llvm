require 'yarv2llvm'
YARV2LLVM::compile_file('sample/e-aux.rb', {:optimize => true, :disasm => false, :dump_yarv =>false, :array_range_check => true})
p compute_e()
