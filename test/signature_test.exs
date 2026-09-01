defmodule Batata.SignatureTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.{Clause, Definition}

  test "keeps arguments to remote native-term stdlib calls boxed" do
    value = Macro.var(:value, nil)
    definition = definition(:encode, value, quote(do: Date.to_iso8601(unquote(value))))

    assert Batata.Signature.infer([definition]) == %{{:encode, 1} => [:term]}
  end

  test "keeps variables embedded in map terms boxed" do
    value = Macro.var(:value, nil)
    definition = definition(:wrap, value, {:%{}, [], [value: value]})

    assert Batata.Signature.infer([definition]) == %{{:wrap, 1} => [:term]}
  end

  test "propagates a proved term ABI through direct local calls" do
    value = Macro.var(:value, nil)
    sink = definition(:sink, value, value)

    forward =
      definition(
        :forward,
        value,
        {:__block__, [], [{:length, [], [value]}, {:sink, [], [value]}]}
      )

    assert Batata.Signature.infer([sink, forward]) == %{
             {:forward, 1} => [:term],
             {:sink, 1} => [:term]
           }
  end

  test "propagates boxed integer literals through local calls" do
    value = Macro.var(:value, nil)
    classify = definition(:classify, value, :ok, {:>=, [], [value, 0]})
    huge = 10_000_000_000_000_000_000_000_000_000_000_000_000
    main = definition(:main, [], {:classify, [], [huge]})

    assert Batata.Signature.infer([classify, main]) == %{
             {:classify, 1} => [:term],
             {:main, 0} => []
           }
  end

  test "infers atom-context variables like source variables" do
    for context <- [nil, Batata.Frontend.DefaultArgExpand] do
      variable = {:value, [generated: context != nil], context}

      scalar = definition(:scalar, variable, {:+, [], [variable, 1]})
      term = definition(:term, variable, {:length, [], [variable]})

      assert Batata.Signature.infer([scalar]) == %{{:scalar, 1} => [:scalar]}
      assert Batata.Signature.infer([term]) == %{{:term, 1} => [:term]}
    end
  end

  test "keeps term equality and membership closure parameters boxed" do
    item = Macro.var(:item, nil)
    collection = Macro.var(:collection, nil)

    atom_equality = definition(:atom_equality, item, {:==, [], [item, :match]})
    membership = definition(:membership, [item, collection], {:in, [], [item, collection]})

    assert Batata.Signature.infer([atom_equality, membership]) == %{
             {:atom_equality, 1} => [:term],
             {:membership, 2} => [:term, :term]
           }
  end

  test "infers a pinned map key and map scrutinee as terms" do
    map = {:map, [], nil}
    key = {:key, [], nil}
    pinned = {:%{}, [], [{{:^, [], [key]}, {:_, [], nil}}]}

    body =
      {:case, [],
       [map, [do: [{:->, [], [[pinned], :match]}, {:->, [], [[{:_, [], nil}], :missing]}]]]}

    lookup = definition(:lookup, [map, key], body)

    assert Batata.Signature.infer([lookup]) == %{{:lookup, 2} => [:term, :term]}
  end

  test "keeps binary_part indexes scalar" do
    binary = Macro.var(:binary, nil)
    start = Macro.var(:start, nil)
    length = Macro.var(:length, nil)

    slice =
      definition(:slice, [binary, start, length], {:binary_part, [], [binary, start, length]})

    assert Batata.Signature.infer([slice]) == %{
             {:slice, 3} => [:term, :scalar, :scalar]
           }
  end

  test "infers qualified Kernel.max operands as scalar integers" do
    value = Macro.var(:value, nil)

    definition =
      definition(
        :clamp,
        value,
        quote(do: Kernel.max(0, -unquote(value)))
      )

    assert Batata.Signature.infer([definition]) == %{{:clamp, 1} => [:scalar]}
  end

  test "infers qualified Kernel min and abs operands as scalar integers" do
    value = Macro.var(:value, nil)

    definition =
      definition(
        :clamp_magnitude,
        value,
        quote(do: Kernel.min(10, Kernel.abs(unquote(value))))
      )

    assert Batata.Signature.infer([definition]) == %{{:clamp_magnitude, 1} => [:scalar]}
  end

  test "keeps the :lists.split list boxed and count scalar" do
    count = Macro.var(:count, nil)
    list = Macro.var(:list, nil)

    definition =
      definition(:split, [count, list], quote(do: :lists.split(unquote(count), unquote(list))))

    assert Batata.Signature.infer([definition]) == %{{:split, 2} => [:scalar, :term]}
  end

  test "keeps the :lists.duplicate item boxed and count scalar" do
    count = Macro.var(:count, nil)
    item = Macro.var(:item, nil)

    definition =
      definition(
        :duplicate,
        [count, item],
        quote(do: :lists.duplicate(unquote(count), unquote(item)))
      )

    assert Batata.Signature.infer([definition]) == %{{:duplicate, 2} => [:scalar, :term]}
  end

  test "marks dynamic closure arguments as terms" do
    closure = {:closure, [], nil}
    value = {:value, [], nil}

    definition =
      definition(
        :apply_closure,
        [closure, value],
        {{:., [], [closure]}, [], [value]}
      )

    assert Batata.Signature.infer([definition]) == %{
             {:apply_closure, 2} => [:term, :term]
           }
  end

  test "uses the term ABI for integer literals in trailing patterns" do
    first = {:first, [], nil}
    second = {:second, [], nil}

    literal = definition(:dispatch, ["  ", 1], :one)
    fallback = definition(:dispatch, [first, second], {:{}, [], [first, second]})

    assert Batata.Signature.infer([literal, fallback]) == %{
             {:dispatch, 2} => [:term, :term]
           }
  end

  test "infers destructured tail parameters as terms without widening tuple scalars" do
    [original, skip, stack, decode, value] =
      Enum.map(~w(original skip stack decode value)a, &Macro.var(&1, nil))

    key = Macro.var(:key, nil)
    acc = Macro.var(:acc, nil)
    rest = Macro.var(:rest, nil)

    body =
      {:__block__, [],
       [
         {:=, [], [[key, {:|, [], [acc, rest]}], stack]},
         {:{}, [], [key, acc, rest, original, skip, decode, value]}
       ]}

    definition =
      definition(
        :object,
        [Macro.var(:tag, nil), original, skip, stack, decode, value],
        body
      )

    assert Batata.Signature.infer([definition]) == %{
             {:object, 6} => [:scalar, :scalar, :scalar, :term, :scalar, :scalar]
           }
  end

  test "infers direct, case, and transitive scalar results to a fixed point" do
    value = {:value, [], nil}

    literal = definition(:literal, [], 65)

    branching =
      definition(
        :branching,
        value,
        {:case, [],
         [
           value,
           [
             do: [
               {:->, [], [[0], 65]},
               {:->, [], [[{:_, [], nil}], {:fail, [], [value]}]}
             ]
           ]
         ]}
      )

    transitive = definition(:transitive, [], {:literal, [], []})
    mixed = definition(:mixed, [], {:if, [], [true, [do: 1, else: :term]]})
    recursive = definition(:recursive, [], {:recursive, [], []})

    assert Batata.Signature.infer_results(
             [transitive, recursive, mixed, branching, literal],
             MapSet.new([{:fail, 1}])
           ) == MapSet.new([{:branching, 1}, {:literal, 0}, {:transitive, 0}])
  end

  test "infers successful cond result contracts independently of the implicit raise" do
    condition = {:condition, [], nil}

    scalar_cond =
      definition(
        :scalar_cond,
        condition,
        {:cond, [],
         [
           [
             do: [
               {:->, [], [[condition], 1]},
               {:->, [], [[true], 2]}
             ]
           ]
         ]}
      )

    boolean_cond =
      definition(
        :boolean_cond,
        condition,
        {:cond, [],
         [
           [
             do: [
               {:->, [], [[condition], {:===, [], [1, 1]}]},
               {:->, [], [[true], {:===, [], [1, 2]}]}
             ]
           ]
         ]}
      )

    mixed_cond =
      definition(
        :mixed_cond,
        condition,
        {:cond, [], [[do: [{:->, [], [[condition], 1]}, {:->, [], [[true], :term]}]]]}
      )

    definitions = [scalar_cond, boolean_cond, mixed_cond]

    assert Batata.Signature.infer_results(definitions) == MapSet.new([{:scalar_cond, 1}])
    assert Batata.Signature.infer_integer_results(definitions) == MapSet.new([{:scalar_cond, 1}])

    assert Batata.Signature.infer_boolean_results(definitions) ==
             MapSet.new([{:boolean_cond, 1}])
  end

  test "infers integer results independently from the scalar ABI" do
    value = {:value, [], nil}
    huge = 10_000_000_000_000_000_000_000_000_000_000_000_000
    boxed = definition(:boxed, [], huge)
    arithmetic = definition(:arithmetic, value, {:*, [], [value, 10]})
    forwarded = definition(:forwarded, value, {:boxed, [], []})

    guarded_identity =
      definition(:guarded_identity, value, value, {:is_integer, [], [value]})

    mixed_integer = definition(:mixed, 0, 1)
    mixed_term = definition(:mixed, value, :not_an_integer)
    identity = definition(:identity, value, value)
    pure_cycle = definition(:pure_cycle, value, {:pure_cycle, [], [value]})

    assert Batata.Signature.infer_integer_results([
             boxed,
             arithmetic,
             forwarded,
             guarded_identity,
             mixed_integer,
             mixed_term,
             identity,
             pure_cycle
           ]) ==
             MapSet.new([
               {:boxed, 0},
               {:arithmetic, 1},
               {:forwarded, 1},
               {:guarded_identity, 1}
             ])
  end

  test "infers recursive boolean results to a fixed point without admitting mixed returns" do
    value = {:value, [], nil}

    recursive =
      definition(
        :recursive,
        value,
        {:and, [],
         [
           {:==, [], [{:rem, [], [value, 2]}, 0]},
           {:recursive, [], [{:div, [], [value, 2]}]}
         ]}
      )

    recursive_base = definition(:recursive, 1, {:==, [], [value, 1]})
    mutual_left = definition(:mutual_left, value, {:mutual_right, [], [value]})
    mutual_right = definition(:mutual_right, value, {:mutual_left, [], [value]})
    mutual_base = definition(:mutual_right, 0, {:==, [], [value, 0]})
    mixed_boolean = definition(:mixed, 0, {:==, [], [value, 0]})
    mixed_term = definition(:mixed, value, :not_a_boolean)
    pure_cycle = definition(:pure_cycle, value, {:pure_cycle, [], [value]})
    no_return = definition(:no_return, value, {:throw, [], [value]})

    assert Batata.Signature.infer_boolean_results([
             recursive,
             recursive_base,
             mutual_left,
             mutual_right,
             mutual_base,
             mixed_boolean,
             mixed_term,
             pure_cycle,
             no_return
           ]) == MapSet.new([{:recursive, 1}, {:mutual_left, 1}, {:mutual_right, 1}])
  end

  test "infers private boolean arguments from every local call site" do
    flag = {:flag, [], nil}

    strict =
      definition(:strict, flag, {:and, [], [flag, {:===, [], [1, 1]}]})

    forwarded = definition(:forwarded, flag, {:strict, [], [flag]})
    main = definition(:main, [], {:forwarded, [], [{:===, [], [1, 1]}]})

    assert Batata.Signature.infer_boolean_arguments([strict, forwarded, main]) == %{
             {:forwarded, 1} => [true],
             {:main, 0} => [],
             {:strict, 1} => [true]
           }
  end

  test "keeps mixed, unknown, public, and uncalled boolean arguments unproven" do
    flag = {:flag, [], nil}
    strict = definition(:strict, flag, {:and, [], [flag, {:===, [], [1, 1]}]})
    unknown = definition(:unknown, flag, {:strict, [], [flag]})
    literal = definition(:literal, [], {:strict, [], [true]})
    uncalled = definition(:uncalled, flag, {:and, [], [flag, true]})

    public =
      %Definition{
        kind: :def,
        name: :public_strict,
        arity: 1,
        clauses: [%Clause{patterns: [flag], body_ast: {:and, [], [flag, true]}}]
      }

    assert Batata.Signature.infer_boolean_arguments([
             strict,
             unknown,
             literal,
             uncalled,
             public
           ]) == %{
             {:literal, 0} => [],
             {:strict, 1} => [false],
             {:uncalled, 1} => [false],
             {:unknown, 1} => [false]
           }
  end

  test "proves integer decoding only at explicit function boundaries" do
    value = {:value, [], nil}
    list = {:list, [], nil}
    index = {:index, [], nil}

    guarded =
      definition(
        :guarded,
        value,
        {:+, [], [value, 1]},
        {:is_integer, [], [value]}
      )

    identity = definition(:identity, value, value)

    list_at_zero = definition(:list_at, [{:|, [], [value, {:_, [], nil}]}, 0], value)

    list_at_tail =
      definition(
        :list_at,
        [{:|, [], [{:_, [], nil}, list]}, index],
        {:list_at, [], [list, {:-, [], [index, 1]}]},
        {:is_integer, [], [index]}
      )

    assert Batata.Signature.infer_integer_guards([
             guarded,
             identity,
             list_at_zero,
             list_at_tail
           ]) == %{
             {:guarded, 1} => [true],
             {:identity, 1} => [false],
             {:list_at, 2} => [false, true]
           }
  end

  defp definition(name, patterns, body) when is_list(patterns) do
    %Definition{
      kind: :defp,
      name: name,
      arity: length(patterns),
      clauses: [%Clause{patterns: patterns, body_ast: body}]
    }
  end

  defp definition(name, pattern, body) do
    definition(name, [pattern], body)
  end

  defp definition(name, patterns, body, guard) when is_list(patterns) do
    %Definition{
      kind: :defp,
      name: name,
      arity: length(patterns),
      clauses: [%Clause{patterns: patterns, guard_ast: guard, body_ast: body}]
    }
  end

  defp definition(name, pattern, body, guard) do
    %Definition{
      kind: :defp,
      name: name,
      arity: 1,
      clauses: [%Clause{patterns: [pattern], guard_ast: guard, body_ast: body}]
    }
  end
end
