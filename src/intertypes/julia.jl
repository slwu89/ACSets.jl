function parse_fields(fieldexprs; mod)
  map(enumerate(fieldexprs)) do (i, fieldexpr)
    @match fieldexpr begin
      Expr(:(::), name, type) => Field{InterType}(name, parse_intertype(type; mod))
      Expr(:(::), type) => Field{InterType}(Symbol("_", i), parse_intertype(type; mod))
    end
  end
end

function parse_variants(variantexprs; mod)
  map(variantexprs) do vexpr
    @match vexpr begin
      tag::Symbol => Variant{InterType}(tag, Field{InterType}[])
      Expr(:call, tag, fieldexprs...) => Variant{InterType}(tag, parse_fields(fieldexprs; mod))
      _ => error("could not parse variant from $vexpr")
    end
  end
end

function parse_typeref(p::RefPath; mod)
  check_typeref(p; mod)
  TypeRef(p)
end

function check_typeref(p::RefPath; mod)
  @match p begin
    RefHere(name) =>
      if !haskey(mod.declarations, name)
        error("name $name not found in module $(mod.name)")
      end
    RefThere(RefHere(extern), name) =>
      if haskey(mod.imports, extern)
        parse_typeref(RefHere(name); mod=mod.imports[extern])
      else
        error("module $mod is not an import of module $(mod.name)")
      end
    _ => error("nested references not supported yet")
  end
end

function parse_intertype(e; mod::InterTypeModule)
  @match e begin
    :Int32 => InterTypes.I32
    :UInt32 => InterTypes.U32
    :Int64 => InterTypes.I64
    :UInt64 => InterTypes.U64
    :Float64 => InterTypes.F64
    :Bool => InterTypes.Boolean
    :String => InterTypes.Str
    :Symbol => InterTypes.Sym
    :Binary => InterTypes.Binary
    T::Symbol => parse_typeref(RefPath(T); mod)
    Expr(:(.), args...) => parse_typeref(RefPath(e); mod)
    Expr(:curly, :Vector, elemtype) =>
      InterTypes.List(parse_intertype(elemtype; mod))
    Expr(:curly, :OrderedDict, keytype, valuetype) =>
      InterTypes.Map(parse_intertype(keytype; mod), parse_intertype(valuetype; mod))
    Expr(:curly, :Record, fieldexprs...) => begin
      InterTypes.Record(parse_fields(fieldexprs; mod))
    end
    Expr(:curly, :Sum, variantexprs...) => begin
      InterTypes.Sum(parse_variants(variantexprs; mod))
    end
    _ => error("could not parse intertype from $e")
  end
end

function parse_intertype_decl(e; mod::InterTypeModule)
  @match e begin
    Expr(:const, Expr(:(=), name::Symbol, type)) => Pair(name, Alias(parse_intertype(type; mod)))
    Expr(:struct, _, name::Symbol, body) => begin
      Base.remove_linenums!(body)
      # this is a hack so we can have recursive data types
      mod.declarations[name] = Alias(TypeRef(RefPath(:nothing)))
      ret = Pair(name, Struct(parse_fields(body.args; mod)))
      delete!(mod.declarations, name)
      ret
    end
    Expr(:sum, name::Symbol, body) => begin
      Base.remove_linenums!(body)
      mod.declarations[name] = Alias(TypeRef(RefPath(:nothing)))
      ret = Pair(name, SumType(parse_variants(body.args; mod)))
      delete!(mod.declarations, name)
      ret
    end
    Expr(:schema, name::Symbol, body) => begin
      Base.remove_linenums!(body)
      Pair(name, SchemaDecl(parse_interschema(body; defined_types)))
    end
    _ => error("could not parse intertype declaration from $e")
  end
end

module InterTypeDeclImplPrivate
macro sum(head, body)
  esc(Expr(:sum, head, body))
end

macro schema(head, body)
  esc(Expr(:schema, head, body))
end
end

function toexpr(field::Field)
  Expr(:(::), field.name, toexpr(field.type))
end

function toexpr(variant::Variant)
  Expr(:call, variant.tag, toexpr.(variant.fields)...)
end

function toexpr(intertype::InterType)
  @match intertype begin
    I32 => :Int32
    U32 => :UInt32
    I64 => :Int64
    U64 => :UInt64
    F64 => :Float64
    Boolean => :Bool
    Str => :String
    Sym => :Symbol
    Binary => :Binary
    List(elemtype) => Expr(:curly, :Vector, toexpr(elemtype))
    Map(keytype, valuetype) => Expr(:curly, :OrderedDict, toexpr(keytype), toexpr(valuetype))
    Record(fields) =>
      Expr(:curly, :Record, toexpr.(fields)...)
    Sum(variants) =>
      Expr(:curly, :Sum, toexpr.(variants)...)
    Annot(desc, innertype) => toexpr(innertype)
    TypeRef(to) => toexpr(to)
  end
end

Base.show(io::IO, intertype::InterType) = print(io, toexpr(intertype))

function toexpr(name::Symbol, decl::InterTypeDecl; show=false)
  @match decl begin
    Alias(type) => :(const $name = $type)
    Struct(fields) =>
      Expr(:macrocall,
        GlobalRef(MLStyle, :(var"@as_record")),
        nothing,
        Expr(:struct,
          false,
          name,
          Expr(:block, toexpr.(fields)...)
        )
      )
    SumType(variants) =>
      Expr(:macrocall,
        GlobalRef(MLStyle, :(var"@data")),
        nothing, name,
        Expr(:block, toexpr.(variants)...)
      )
  end
end

function Base.show(io::IO, declpair::Pair{Symbol, InterTypeDecl})
  (name, decl) = declpair
  print(io, toexpr(name, decl; show=true))
end

function as_intertypes(mod::InterTypeModule)
  function parse(in::Expr)
    Base.remove_linenums!(in)
    in = macroexpand(InterTypeDeclImplPrivate, in)
    (name, decl) = parse_intertype_decl(in; mod)
    mod.declarations[name] = decl
    out = Expr(:block)
    push!(out.args, toexpr(name, decl))
    @match decl begin
      SumType(variants) => begin
        for variant in variants
          mod.declarations[variant.tag] = InterTypes.VariantOf(name)
        end
      end
      _ => nothing
    end
    push!(out.args, eqmethods(name, decl))
    push!(out.args, reader(name, decl))
    push!(out.args, :(eval($(Expr(:quote, writer(name, decl))))))
    out
  end
end

function include_intertypes(into::Module, file::String, imports::AbstractVector)
  endswith(file, ".it") || error("expected a file ending in \".it\"")
  name = Symbol(chop(file; tail=3))
  mod = InterTypeModule(name, OrderedDict{Symbol, InterTypeModule}(imports))
  into.include(as_intertypes(mod), file)
  # recompute the hash
  mod = InterTypeModule(name, mod.imports, mod.declarations)
  into.eval(Expr(:export, keys(mod.declarations)...))
  mod
end

macro intertypes(file, modexpr)
  name, imports = @match modexpr begin
    Expr(:module, _, name, body) => begin
      imports = Symbol[]
      for line in body.args
        @match line begin
          Expr(:import, Expr(:(.), :(.), :(.), name)) => push!(imports, name)
          _ => nothing
        end
      end
      (name, imports)
    end
    _ => error("expected a module expression, got $modexpr")
  end
  imports = Expr(:vect, [:($(Expr(:quote, name)) => $name.Meta) for name in imports]...)
  Expr(
    :toplevel,
    esc(modexpr),
    :($(esc(name)).Meta = include_intertypes($(esc(name)), $file, $(esc(imports)))),
    esc(name),
  )
end

function eqmethod(name::Symbol, fields::Vector{Field{InterType}})
  quote
    function Base.:(==)(a::$name, b::$name)
      Base.all([$([:(a.$x == b.$x) for x in nameof.(fields)]...)])
    end
  end
end

function eqmethods(name, decl::InterTypeDecl)
  @match decl begin
    Alias(_) => nothing
    Struct(fields) => eqmethod(name, fields)
    SumType(variants) =>
      Expr(:block, map(variants) do variant
        eqmethod(variant.tag, variant.fields)
    end...)
  end
end

function variantreader(name::Symbol, fields::Vector{Field{InterType}})
  fieldreads = map(fields) do field
    :($(read)(format, $(toexpr(field.type)), s[$(Expr(:quote, field.name))]))
  end
  :($name($(fieldreads...)))
end

function makeifs(branches)
  makeifs(branches[1:end-1], branches[end][2])
end

function makeifs(branches, elsebody)
  expr = elsebody
  if length(branches) == 0
    return expr
  end
  for (cond, body) in Iterators.reverse(branches[2:end])
    expr = Expr(:elseif, cond, body, expr)
  end
  (cond, body) = branches[1]
  Expr(:if, cond, body, expr)
end

function reader(name, decl::InterTypeDecl)
  body = @match decl begin
    Alias(_) => nothing
    Struct(fields) => variantreader(name, fields)
    SumType(variants) => begin
      tag = gensym(:tag)
      ifs = makeifs(map(variants) do variant
        (
          :($tag == $(string(variant.tag))),
          variantreader(variant.tag, variant.fields)
        )
      end)
      quote
        $tag = s[:_type]
        $ifs
      end
    end
    SchemaDecl(_) => nothing
  end
  if !isnothing(body)
    :(function $(GlobalRef(InterTypes, :read))(format::$(JSONFormat), ::Type{$(name)}, s::$(JSON3.Object))
      $body
    end)
  else
    nothing
  end
end

function writejsonfield(io, name, value, comma=true)
  print(io, "\"", string(name), "\":")
  write(io, JSONFormat(), value)
  if comma
    print(io, ",")
  end
end

function fieldwriters(fields)
  map(enumerate(fields)) do (i, field)
    (name, expr) = field
    comma = i != length(fields)
    :($(writejsonfield)(io, $(string(name)), $expr, $comma))
  end
end

function objectwriter(fields)
  quote
    print(io, "{")
    $(fieldwriters(fields)...)
    print(io, "}")
  end
end

function writer(name, decl::InterTypeDecl)
  body = @match decl begin
    Alias(_) => nothing
    Struct(fields) => begin
      objectwriter([(field.name, :(d.$(field.name))) for field in fields])
    end
    SumType(variants) => begin
      variantlines = map(variants) do variant
        fieldnames = nameof.(variant.fields)
        fieldvars = gensym.(fieldnames)
        Expr(
          :call, :(=>),
          :($(variant.tag)($(fieldvars...))),
          Expr(
            :block,
            fieldwriters([(:_type, string(variant.tag)), zip(fieldnames, fieldvars)...])...
          )
        )
      end
      quote
        print(io, "{")
        $(Expr(
          :macrocall, GlobalRef(MLStyle, :(var"@match")), nothing, :d,
          Expr(:block, variantlines...)
        ))
        print(io, "}")
      end
    end
    _ => nothing
  end
  if !isnothing(body)
    :(function $(GlobalRef(InterTypes, :write))(io::IO, format::$(JSONFormat), d::$(name))
      $body
    end)
  else
    nothing
  end
end