#!/bin/ruby 
#
#  Type information class of Ruby or llvm
#

module YARV2LLVM
  include LLVM

class RubyType
  include LLVM
  include RubyHelpers

  @@type_table = []

  def initialize(type, lno = nil, name = nil, klass = nil)
    @name = name
    @line_no = lno
    if type == nil 
      @type = nil
    elsif type.is_a?(ComplexType) then
      @type = type
    else
      @type = PrimitiveType.new(type, klass)
    end

#      @klass = klass.name.to_sym

    @resolveed = false
    @same_type = []
    @same_value = []
    @@type_table.push self
    @conflicted_types = Hash.new(0)
  end
  attr_accessor :type
  attr_accessor :conflicted_types

  def klass
    if @type then
      @type.klass
    else
      nil
    end
  end

  def dup_type
    no = clone
    if @type then
      no.type = @type.clone
      no.type.constant = nil
      no.type.content = nil
    end
    add_same_type no
    no.add_same_type self
    no
  end

  def inspect2
    if @type then
      @type.inspect2
    else
      'nil'
    end
  end

  attr_accessor :type
  attr_accessor :resolveed
  attr :name
  attr :line_no

  def add_same_type(fty)
    @same_type.push fty
    # Complex type -> element type is same also.
    if @type.is_a?(ComplexType) and fty.type.is_a?(ComplexType) then
      if fty.type.element_type.type.llvm != VALUE then
        @type.element_type.add_same_type(fty.type.element_type)
      end
    end
    # for debug
    #    RubyType.resolve
  end

  def add_same_value(fty)
    @same_value.push fty
    # Complex type -> element type is same also.
    if @type.is_a?(ComplexType) and fty.type.is_a?(ComplexType) then
      if fty.type.element_type.type.llvm != VALUE then
        @type.element_type.add_same_value(fty.type.element_type)
      end
    end
    # for debug
    #    RubyType.resolve
  end
  
  def clear_same
    @same_type = []
    @same_value = []
  end

  def self.clear_content
    @@type_table.each do |ty|
      if ty.type then
        ty.type.content = nil
        if ty.type.is_a?(ArrayType) then
          ty.type.ptr = nil
          ty.type.element_content = {}
        end
      end
    end
  end

  def self.resolve
    @@type_table.each do |ty|
      ty.resolveed = false
    end

    @@type_table.each do |ty|
      ty.resolve
    end

#    @@type_table.each do |ty|
#      ty.clear_same
#    end
  end

  def resolve
    rone = lambda {|dupp|
      lambda {|ty|
        if ty.type and ty.type.is_a?(ComplexType) then
          if ty.type.is_a?(@type.class) and ty.type.class != @type.class then
            if dupp then
              @type = ty.type.dup_type
            else
              @type = ty.type
            end
            @resolveed = false
            resolve
            return
          end
          
          if @type.is_a?(ty.type.class) then
            if ty.type != @type then
              if dupp then
                ty.type = @type.dup_type
              else
                ty.type = @type
              end
            end
            ty.resolve
            next
          end

          if @type.llvm == VALUE then
            return
          end
        end
        
        ty.conflicted_types.merge!(@conflicted_types)
        if ty.type and ty.type.llvm != @type.llvm then
          mess = "Type conflict \n"
          mess += "  #{ty.name}(#{ty.type.inspect2}) defined in #{ty.line_no} \n"
          mess += "  #{@name}(#{@type.inspect2}) define in #{@line_no} \n"
          if OPTION[:strict_type_inference] then
            raise mess
          else
            if OPTION[:type_message] then
              print mess
            end

            ty.conflicted_types[ty.type.klass] = ty.type
            ty.type = PrimitiveType.new(VALUE, Object)
         end

        elsif ty.type then
          if dupp then
            ty.type = @type.dup_type
          end
        else
          if dupp then
            ty.type = @type.dup_type
          else
            ty.type = @type
          end
          ty.resolve
        end
      }
    }

    if @resolveed then
      return
    end

    if @type then
      @resolveed = true
      rone_dup = rone.call(true)
      @same_type.each(&rone_dup)
      rone_nodup = rone.call(false)
      @same_value.each(&rone_nodup)
    end
  end

  def self.fixnum(lno = nil, name = nil, klass = Fixnum)
    RubyType.new(Type::Int32Ty, lno, name, klass)
  end

  def self.boolean(lno = nil, name = nil, klass = TrueClass)
    RubyType.new(Type::Int1Ty, lno, name, klass)
  end

  def self.float(lno = nil, name = nil, klass = Float)
    RubyType.new(Type::DoubleTy, lno, name, klass)
  end

  def self.string(lno = nil, name = nil, klass = String)
    RubyType.new(StringType.new, lno, name, klass)
  end

  def self.array(lno = nil, name = nil)
    na = ArrayType.new(nil)

    etype = RubyType.new(nil)
    na.element_type = etype

    RubyType.new(na, lno, name, Array)
  end

  # hash is already define by Ruby system
  def self.hashtype(lno = nil, name = nil)
    na = HashType.new(nil)

    etype = RubyType.new(nil)
    na.element_type = etype

    RubyType.new(na, lno, name, Hash)
  end

  def self.struct(lno = nil, name = nil)
    na = StructType.new
    RubyType.new(na, lno, name, Struct)
  end

  def self.range(fst, lst, excl, lno = nil, name = nil)
    na = RangeType.new(fst, lst, excl)
    RubyType.new(na, lno, name, Range)
  end

  def self.symbol(lno = nil, name = nil, klass = Symbol)
    RubyType.new(VALUE, lno, name, klass)
  end

  def self.value(lno = nil, name = nil, klass = Object)
    RubyType.new(VALUE, lno, name, klass)
  end

  def self.from_sym(sym, lno, name)
    case sym
    when :Fixnum
      RubyType.fixnum(lno, name)

    when :Float
      RubyType.float(lno, name)

    when :String
      RubyType.string(lno, name)

    when :Symbol
      RubyType.symbol(lno, name)

    when :Array
      RubyType.array(lno, name)

    when :Hash
      RubyType.hashtype(lno, name)

    else
      obj = nil
      if sym then
        obj = Object.const_get(sym, true)
      end
      unless obj
        obj = Object
      end

      RubyType.value(lno, name, obj)
    end
  end

  def self.typeof(obj, lno = nil, name = nil)
    case obj
    when ::TrueClass, ::FalseClass
      RubyType.boolean(lno, name)

    when ::Fixnum
      RubyType.fixnum(lno, name)

    when ::Float
      RubyType.float(lno, name)

    when ::String
      RubyType.string(lno, obj)

    when ::Symbol
      RubyType.symbol(lno, obj)

    when ::Array
      RubyType.array(lno, obj)

    when ::Hash
      RubyType.hashtype(lno, obj)

    when ::Range
      fst = RubyType.typeof(obj.first, nil, obj.first)
      fst.type.constant = obj.first.llvm
      lst = RubyType.typeof(obj.last, nil, obj.last)
      lst.type.constant = obj.last.llvm
      exc = RubyType.typeof(obj.exclude_end?, nil, obj.exclude_end?)
      exc.type.constant = obj.exclude_end?.llvm
      RubyType.range(fst, lst, exc, lno, obj)

    when ::Class
      RubyType.value(lno, obj, obj)

    when ::Module
      RubyType.value(lno, obj, obj)

    else
      RubyType.value(lno, obj, obj.class)
    end
  end
end

class PrimitiveType
  include LLVM
  include RubyHelpers

  def initialize(type, klass)
    if klass.is_a?(Symbol) then
      @klass = klass
    elsif klass then
      @klass = klass.name.to_sym
    else
      @klass = nil
    end
    @type = type
    @content = nil
    @constant = nil
  end

  attr_accessor :klass
  attr_accessor :content
  attr_accessor :constant

  def dup_type
    nt = self.class.new(@type, @klass)
    nt
  end

  TYPE_HANDLER = {
    Type::Int32Ty =>
      {:inspect => "Int32Ty",

       :to_value => lambda {|val, b, context|
         x = b.shl(val, 1.llvm)
         b.or(FIXNUM_FLAG, x)
       },

       :from_value => lambda {|val, b, context|
         x = b.ashr(val, 1.llvm)
       },
      },

    Type::Int8Ty =>
      {:inspect => "Char",

       :to_value => lambda {|val, b, context|
         val32 = b.zext(val, Type::Int32Ty)
         x = b.shl(val32, 1.llvm)
         b.or(FIXNUM_FLAG, x)
       },

       :from_value => lambda {|val, b, context|
         val32 = b.zext(val, Type::Int32Ty)
         x = b.lshr(val32, 1.llvm)
       },
      },

    Type::Int1Ty =>
      {:inspect => "Boolean",

       :to_value => lambda {|val, b, context|
         val32 = b.zext(val, Type::Int32Ty)
         b.shl(val32, 1.llvm)
       },

       :from_value => lambda {|val, b, context|
         x = b.and(val, (~4).llvm)
         b.icmp_ne(x, 0.llvm)
       },
      },

    Type::DoubleTy =>
      {:inspect => "DoubleTy",

       :to_value => lambda {|val, b, context|
        atype = [Type::DoubleTy]
        ftype = Type.function(VALUE, atype)
        func = context.builder.external_function('rb_float_new', ftype)
        b.call(func, val)
       },

       :from_value => lambda {|val, b, context|
        val_ptr = b.int_to_ptr(val, P_RFLOAT)
        dp = b.struct_gep(val_ptr, 1)
        b.load(dp)
       },
      },

    VALUE =>
#    {:inspect => "VALUE (#{@type ? @type.conflicted_types.map{|t, v| t.klass} : ''})",
    {:inspect => "VALUE",

       :to_value => lambda {|val, b, context|
        val
       },

       :from_value => lambda {|val, b, context|
        val
       },
      },

    P_CHAR =>
      {:inspect => "P_CHAR",

       :to_value => lambda {|val, b, context|
        raise "Illigal convert P_CHAR to VALUE"
       },

       :from_value => lambda {|val, b, context|
        raise "Illigal convert VALUE to P_CHAR"
       },
      },
  }

  def to_value(val, b, context)
    TYPE_HANDLER[@type][:to_value].call(val, b, context)
  end

  def from_value(val, b, context)
    TYPE_HANDLER[@type][:from_value].call(val, b, context)
  end

  def inspect2
    if rc = TYPE_HANDLER[@type] then
      "#{rc[:inspect]} (#{@klass})"
    else
      self.inspect
    end
  end

  def llvm
    @type
  end
end

class ComplexType
  def set_klass(klass)
    if klass.is_a?(::Class) then
      @klass = klass.name.to_sym
    elsif klass.is_a?(Symbol) then
      @klass = klass.to_sym
    else
      @klass = nil
    end
    @constant = nil
  end

  attr_accessor :klass
  attr_accessor :constant

  def dup_type
    self.class.new
  end

  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end
end

class RangeType<ComplexType
  include LLVM
  include RubyHelpers

  def initialize(first, last, excl)
    set_klass(Range)
    @first = first
    @last = last
    @excl = excl
    @content = nil
  end
  attr_accessor :first
  attr_accessor :last
  attr_accessor :excl
  attr_accessor :content

  def dup_type
    dup
  end

  def llvm
    VALUE
  end

  def element_type
    @first
  end

  def inspect2
    "Range(#{@first.inspect2})"
  end
end

class AbstructContainerType<ComplexType
  include LLVM
  include RubyHelpers

  def initialize(etype)
    set_klass(Object)
    @element_type = RubyType.new(etype)
    @content = nil
  end
  attr_accessor :element_type
  attr_accessor :content

  def dup_type
    no = self.class.new(nil)
    no.element_type = @element_type
    no
  end

  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end

  def llvm
    VALUE
  end

  def inspect2
    "Abstruct Contanor type of #{@element_type.inspect2}"
  end
end

class ArrayType<AbstructContainerType
  include LLVM
  include RubyHelpers

  def initialize(etype)
    set_klass(Array)
    @element_type = RubyType.new(etype, nil, nil)
    @ptr = nil
    @element_content = Hash.new
  end
  attr_accessor :element_type
  attr_accessor :ptr
  attr_accessor :element_content

  def dup_type
    no = self.class.new(nil)
    no.element_type = @element_type
    no
  end

  def has_cycle_aux(r, t)
    if r == t then
      return true
    else
      if r.is_a?(ComplexType) and 
         t.is_a?(ComplexType) and 
         r.element_type.type.is_a?(ComplexType) then
        r = r.element_type.type.element_type.type
        t = t.element_type.type
        return has_cycle_aux(r, t)
      else
        return false
      end
    end
  end

  def has_cycle?
    has_cycle_aux(@element_type.type, self)
  end

  def inspect2
    if @element_type then
      if has_cycle? then
        "Array of VALUE"
      else
        "Array of #{@element_type.inspect2}"
      end
    else
      "Array of nil"
    end
  end

  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end

  def llvm
    VALUE
  end
end

class HashType<AbstructContainerType
  include LLVM
  include RubyHelpers

  def initialize(etype)
    set_klass(Hash)
    @element_type = RubyType.new(etype, nil, nil)
    @ptr = nil
    @element_content = Hash.new
  end
  attr_accessor :element_type
  attr_accessor :ptr
  attr_accessor :element_content

  def dup_type
    no = self.class.new(nil)
    no.element_type = @element_type
    no
  end

  def has_cycle_aux(r, t)
    if r == t then
      return true
    else
      if r.is_a?(ComplexType) and 
         t.is_a?(ComplexType) and 
         r.element_type.type.is_a?(ComplexType) then
        r = r.element_type.type.element_type.type
        t = t.element_type.type
        return has_cycle_aux(r, t)
      else
        return false
      end
    end
  end

  def has_cycle?
    has_cycle_aux(@element_type.type, self)
  end

  def inspect2
    if @element_type then
      if has_cycle? then
        "Hash of VALUE"
      else
        "Hash of #{@element_type.inspect2}"
      end
    else
      "Hash of nil"
    end
  end

  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end

  def llvm
    VALUE
  end
end

class StringType<AbstructContainerType
  include LLVM
  include RubyHelpers

  def initialize
    set_klass(String)
    @element_type = RubyType.new(CHAR, nil, nil, Fixnum)
  end
  attr :element_type

  def dup_type
    no = self.class.new
    no
  end

  def inspect2
    "String"
  end

  def to_value(val, b, context)
    ftype = Type.function(VALUE, [P_CHAR])
    func = context.builder.external_function('rb_str_new_cstr', ftype)
    b.call(func, val)
  end

  def from_value(val, b, context)
    ftype = Type.function(P_CHAR, [P_VALUE])
    func = context.builder.external_function('rb_string_value_ptr', ftype)
    strp = b.alloca(VALUE, 1)
    b.store(val, strp)
    b.call(func, strp)
  end

  def llvm
    P_CHAR
  end
end

class StructType<AbstructContainerType
  include LLVM
  include RubyHelpers

  def initialize
    set_klass(Struct)
    @element_type = RubyType.new(VALUE, nil, nil, Object)
  end
  attr :element_type

  def dup_type
    no = self.class.new
    no
  end

  def inspect2
    "Struct"
  end

  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end

  def llvm
    VALUE
  end
end
end

