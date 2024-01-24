export JSONTarget, tojsonschema, jsonwrite, jsonread

using OrderedCollections
using Base64
using MLStyle
import JSON3
using CompTime

using ..ACSetInterface
using ..DenseACSets

"""
A signifier for serialization to and from JSON.
"""
struct JSONFormat <: SerializationFormat
end

struct InterTypeConversionError <: Exception
  expected::InterType
  got::Any
end

"""
    read(format::SerializationFormat, type::Type, x)

A generic read method dispatch-controlled by format of the input and expected
type.

TODO: Currently this *shadows* Base.read, instead of overloading it. Would it
be type piracy to overload it instead?
"""
function read(format::SerializationFormat, type::Type, x)
  throw(InterTypeConversionError(intertype(type), x))
end

"""
    write(io::IO, format::SerializationFormat, x)

Writes `x` the the provided IO stream, using serialization format `format`.

See docstring for [`read`](@ref) about shadowing vs. overloading Base.write.
"""
function write end

"""
    joinwith(io::IO, f, xs, separator)

Prints the elements in `xs` using `x -> f(io, x)`, separated by `separator`.
"""
function joinwith(io::IO, f, xs, separator)
  for x in xs[1:end-1]
    f(io, x)
    print(io, separator)
  end
  f(io, xs[end])
end

"""
    jsonwrite(x)
    jsonwrite(io::IO, x)

A wrapper around [`write`](@ref) which calls it with [`JSONFormat`](@ref).

TODO: Should we just overload JSON3.write instead? See [1]

[1]: https://github.com/AlgebraicJulia/ACSets.jl/issues/83
"""
jsonwrite(x) = sprint(jsonwrite, x)
jsonwrite(io::IO, x) = write(io, JSONFormat(), x)

"""
    jsonread(s::String, T::Type)

A wrapper around [`read`](@ref) which calls it with [`JSONFormat`](@ref)

TODO: See comment for [`jsonwrite`](@ref)
"""
function jsonread(s::String, ::Type{T}) where {T}
  json = JSON3.read(s)
  read(JSONFormat(), T, json)
end

# JSON Serialization for basic types
####################################

# We write our own serialization methods instead of using JSON3.write directly
# because we want to serialize 64 bit integers as strings rather than integers
# which get lossily converted to floats.

intertype(::Type{Nothing}) = Unit
read(::JSONFormat, ::Type{Nothing}, ::Nothing) = nothing
write(io::IO, ::JSONFormat, ::Nothing) = print(io, "null")

intertype(::Type{Int32}) = I32
read(::JSONFormat, ::Type{Int32}, s::Real) = Int32(s)
write(io::IO, ::JSONFormat, d::Int32) = print(io, d)

intertype(::Type{UInt32}) = U32
read(::JSONFormat, ::Type{UInt32}, s::Real) = UInt32(s)
write(io::IO, ::JSONFormat, d::UInt32) = print(io, d)

intertype(::Type{Int64}) = I64
read(::JSONFormat, ::Type{Int64}, s::String) = parse(Int64, s)
read(::JSONFormat, ::Type{Int64}, s::Integer) = Int64(s)
write(io::IO, ::JSONFormat, d::Int64) = print(io, "\"", d, "\"")

intertype(::Type{UInt64}) = U64
read(::JSONFormat, ::Type{UInt64}, s::String) = parse(UInt64, s)
read(::JSONFormat, ::Type{UInt64}, s::Integer) = UInt64(s)
write(io::IO, ::JSONFormat, d::UInt64) = print(io, "\"", d, "\"")

intertype(::Type{Float64}) = F64
read(::JSONFormat, ::Type{Float64}, s::Real) = Float64(s)
write(io::IO, ::JSONFormat, d::Float64) = print(io, d)

intertype(::Type{Bool}) = Boolean
read(::JSONFormat, ::Type{Bool}, s::Bool) = s
write(io::IO, ::JSONFormat, d::Bool) = print(io, d)

intertype(::Type{String}) = Str
read(::JSONFormat, ::Type{String}, s::String) = s
write(io::IO, ::JSONFormat, d::String) = JSON3.write(io, d)

intertype(::Type{Symbol}) = Sym
read(::JSONFormat, ::Type{Symbol}, s::String) = Symbol(s)
write(io::IO, ::JSONFormat, d::Symbol) = JSON3.write(io, string(d))

intertype(::Type{Vector{UInt8}}) = Binary
read(::JSONFormat, ::Type{Vector{UInt8}}, s::String) = base64decode(s)
function write(io::IO, ::JSONFormat, d::Vector{UInt8})
  print(io, "\"")
  Base.write(io, base64encode(d))
  print(io, "\"")
end

intertype(::Type{Vector{T}}) where {T} = List(intertype(T))
function read(format::JSONFormat, ::Type{Vector{T}}, s::JSON3.Array) where {T}
  res = T[]
  for elt in s
    push!(res, read(format, T, elt))
  end
  res
end
function write(io::IO, format::JSONFormat, d::Vector{T}) where {T}
  print(io, "[")
  if length(d) > 0 joinwith(io, (io, x) -> write(io, format, x), d, ",") end
  print(io, "]")
end

intertype(::Type{Object{T}}) where {T} = ObjectType{intertype(T)}
function read(format::JSONFormat, ::Type{Object{T}}, s::JSON3.Object) where {T}
  Object{T}(
    [k => read(format, T, v) for (k, v) in pairs(s)]...
  )
end
function write(io::IO, format::JSONFormat, d::Object)
  writeobject(io) do next
    for p in pairs(d)
      next()
      writekv(io, p)
    end
  end
end

intertype(::Type{Optional{T}}) where {T} = Optional{intertype(T)}
read(::JSONFormat, ::Type{Optional{T}}, ::Nothing) where {T} = nothing
read(format::JSONFormat, ::Type{Optional{T}}, s) where {T} =
  read(format, T, s)

intertype(::Type{OrderedDict{K,V}}) where {K,V} = Map(intertype(K), intertype(V))
function read(format::JSONFormat, ::Type{OrderedDict{K, V}}, s::JSON3.Array) where {K, V}
  res = OrderedDict{K, V}()
  for elt in s
    (;key, value) = read(format, NamedTuple{(:key, :value), Tuple{K, V}}, elt)
    res[key] = value
  end
  res
end
function write(io::IO, format::JSONFormat, d::OrderedDict{K, V}) where {K, V}
  print(io, "[")
  joinwith(io, (io, x) -> write(io, format, (key=x[1], value=x[2])), collect(pairs(d)), ",")
  print(io, "]")
end

function intertype(::Type{T}) where {T<:Tuple}
  types = T.parameters
  Record(map(enumerate(types)) do (i, type)
    Field{InterType}(Symbol("_", i), intertype(type))
  end)
end
function read(format::JSONFormat, ::Type{T}, s::JSON3.Object) where {T<:Tuple}
  keys = Tuple([Symbol("_", i) for i in 1:length(T.parameters)])
  Tuple(read(format, NamedTuple{keys, T}, s))
end
function write(io::IO, format::JSONFormat, d::T) where {T<:Tuple}
  keys = Tuple([Symbol("_", i) for i in 1:length(T.parameters)])
  write(io, format, NamedTuple{keys, T}(d))
end

function intertype(::Type{NamedTuple{names, T}}) where {names, T<:Tuple}
  types = T.parameters
  Record([Field{InterType}(name, intertype(type)) for (name, type) in zip(names, (types))])
end
# TODO: comptime this
function read(format::JSONFormat, ::Type{NamedTuple{names, T}}, s::JSON3.Object) where {names, T<:Tuple}
  keys(s) == Set(names) || error("wrong keys: expected $names got $(keys(s))")
  vals = Any[]
  for (name, type) in zip(names, T.parameters)
    push!(vals, read(format, type, s[name]))
  end
  NamedTuple{names, T}(vals)
end
function write(io::IO, format::JSONFormat, d::NamedTuple{names, T}) where {names, T<:Tuple}
  writeobject(io) do next
    for p in pairs(d)
      next()
      writekv(io, p)
    end
  end
end

function read(format::JSONFormat, ::Type{T}, s::JSON3.Object) where {S, Ts, T <: StructACSet{S, Ts}}
  schema = Schema(S)
  acs = T()
  for ob in objects(schema)
    add_parts!(acs, ob, length(s[ob]))
  end
  for at in attrtypes(schema)
    if haskey(s, at)
      add_parts!(acs, at, length(s[at]))
    end
  end
  typing = Dict{Symbol, Type}(zip(attrtypes(schema), Ts.parameters))
  for ob in objects(schema)
    for jsonobject in s[ob]
      i = jsonobject[:_id]
      for f in homs(schema; from=ob, just_names=true)
        acs[i, f] = read(format, Int, jsonobject[f])
      end
      for (f, _, t) in attrs(schema; from=ob)
        acs[i, f] = read(format, typing[t], jsonobject[f])
      end
    end
  end
  acs
end

writekey(io::IO, key) = print(io, "\"", key, "\":")

function writekv(io, kv::Pair{Symbol, T}) where {T}
  (k, v) = kv
  writekey(io, k)
  write(io, JSONFormat(), v)
end

function writeitems(f, io)
  first = true
  function next()
    if !first
      print(io, ",")
    end
    first = false
  end
  f(next)
end

function writeobject(f, io)
  print(io, "{")
  writeitems(f, io)
  print(io, "}")
end

function writearray(f, io)
  print(io, "[")
  writeitems(f, io)
  print(io, "]")
end

function write(io::IO, format::JSONFormat, acs::ACSet)
  schema = acset_schema(acs)
  writeobject(io) do next
    for ob in objects(schema)
      next()
      writekey(io, ob)
      writearray(io) do next
        for i in parts(acs, ob)
          next()
          writeobject(io) do next
            next()
            writekv(io, :_id => Int32(i))
            for f in homs(schema; from=ob, just_names=true)
              next()
              writekv(io, f => Int32(acs[i, f]))
            end
            for f in attrs(schema; from=ob, just_names=true)
              next()
              writekv(io, f => acs[i, f])
            end
          end
        end
      end
    end
    for at in attrtypes(schema)
      next()
      writekey(io, at)
      writearray(io) do next
        for i in parts(acs, at)
          next()
          write(io, format, (:_id, i))
        end
      end
    end
  end
end

# JSONSchema Export
###################

function fieldproperties(fields::Vector{Field{InterType}})
  map(fields) do field
    field.name => tojsonschema(field.type)
  end
end

"""
    tojsonschema(type::InterType)

Convert an InterType to a JSONSchema representation.

TODO: We could use multiple dispatch instead of the `@match` here, which might
be cleaner
"""
function tojsonschema(type::InterType)
  @match type begin
    I32 => Object(
      :type => "integer",
      Symbol("\$comment") => "I32",
      :minimum => typemin(Int32),
      :maximum => typemax(Int32)
    )
    U32 => Object(
      :type => "integer",
      Symbol("\$comment") => "U32",
      :minimum => typemin(UInt32),
      :maximum => typemax(UInt32)
    )
    I64 => Object(
      :type => "string",
      Symbol("\$comment") => "I64"
    )
    U64 => Object(
      :type => "string",
      Symbol("\$comment") => "U64"
    )
    F64 => Object(
      :type => "number",
      Symbol("\$comment") => "F64"
    )
    Boolean => Object(
      :type => "boolean",
      Symbol("\$comment") => "Boolean"
    )
    Str => Object(
      :type => "string",
      Symbol("\$comment") => "Str"
    )
    Sym => Object(
      :type => "string",
      Symbol("\$comment") => "Sym"
    )
    Binary => Object(
      :type => "string",
      :contentEncoding => "base64",
      Symbol("\$comment") => "Binary"
    )
    OptionalType(elemtype) => begin
      schema = tojsonschema(elemtype)
      schema[:type] = [schema[:type], "null"]
      schema
    end
    ObjectType(elemtype) => Object(
      :type => "object",
      :additionalProperties => tojsonschema(elemtype)
    )
    List(elemtype) => Object(
      :type => "array",
      :items => tojsonschema(elemtype)
    )
    Map(keytype, valuetype) => Object(
      :type => "array",
      :items => Object(
        :type => "object",
        :properties => Object(
          :key => tojsonschema(keytype),
          :value => tojsonschema(valuetype)
        )
      )
    )
    Record(fields) => recordtype(fields)
    Sum(variants) => Object(
      "oneOf" => Vector{Object}(varianttype.(variants))
    )
    Annot(desc, innertype) => begin
      innerschematype = tojsonschema(innertype)
      innerschematype["description"] = desc
      innerschematype
    end
    TypeRef(to) => reftype(string(toexpr(to)))
  end
end

reftype(name) = Object(
  Symbol("\$ref") => "#/\$defs/$(name)"
)

recordtype(fields) = Object(
  :type => "object",
  :properties => Object(fieldproperties(fields)...),
  :required => string.(nameof.(fields))
)

varianttype(variant) = Object(
  :type => "object",
  :properties => Object(
    :tag => Object(
      :const => string(variant.tag)
    ),
    fieldproperties(variant.fields)...
  ),
  :required => string.(nameof.(variant.fields))
)

function acsettype(spec)
  tablespecs = map(objects(spec.schema)) do ob
    idfield = Field{InterType}(:_id, U32)
    homfields = map(homs(spec.schema; from=ob, just_names=true)) do f
      Field{InterType}(f, U32)
    end
    attrfields = map(attrs(spec.schema; from=ob)) do (f, _, t)
      Field{InterType}(f, spec.schema.typing[t])
    end
    Field{InterType}(ob, List(Record([idfield; homfields; attrfields])))
  end
  Object(
    :type => "object",
    :properties => recordtype(tablespecs)
  )
end

"""
    JSONTarget  

Specifies a serialization target of JSON Schema when
generating a module.

TODO: This should really be called something like JSONSchemaTarget.
"""
struct JSONTarget <: SerializationTarget end

# TODO: Should this be ::JSONTarget instead of ::Type{JSONTarget} so
# that we pass in `JSONTarget()` instead of `JSONTarget`?
function generate_module(
  mod::InterTypeModule, ::Type{JSONTarget}, path
  ;ac=JSON3.AlignmentContext(indent=2)
)
  defs = Pair{Symbol, Object}[]
  for (name, decl) in mod.declarations
    @match decl begin
      Alias(type) => push!(defs, name => tojsonschema(type))
      Struct(fields) => push!(defs, name => recordtype(fields))
      VariantOf(parent) => begin
        sum = mod.declarations[parent]
        variant = only(filter(v -> v.tag == name, sum.variants))
        push!(defs, name => varianttype(variant))
      end
      SumType(variants) => 
        push!(defs, name => Object(:oneOf => reftype.([v.tag for v in variants])))
      NamedACSetType(spec) => 
        push!(defs, name => acsettype(spec))
      _ => nothing
    end
  end
  schema = Object(
    Symbol("\$schema") => "http://json-schema.org/draft-07/schema#",
    Symbol("\$defs") => Object(defs...)
  )
  schema_filepath = joinpath(path, string(mod.name)*"_schema.json") 
  open(schema_filepath, "w") do io
    JSON3.pretty(io, schema, ac)
  end
end
