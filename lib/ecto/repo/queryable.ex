defmodule Ecto.Repo.Queryable do
  # The module invoked by user defined repos
  # for query related functionality.
  @moduledoc false

  alias Ecto.Queryable
  alias Ecto.Query.Planner

  require Ecto.Query

  @doc """
  Implementation for `Ecto.Repo.all/2`
  """
  def all(repo, adapter, queryable, opts) when is_list(opts) do
    id_types = adapter.id_types(repo)

    {query, params} =
      Queryable.to_query(queryable)
      |> Planner.query(:all, id_types)

    adapter.all(repo, query, params, preprocess(query.sources, id_types), opts)
    |> Ecto.Repo.Assoc.query(query)
    |> Ecto.Repo.Preloader.query(repo, query, postprocess(query.select))
  end

  @doc """
  Implementation for `Ecto.Repo.get/3`
  """
  def get(repo, adapter, queryable, id, opts) do
    one(repo, adapter, query_for_get(queryable, id), opts)
  end

  @doc """
  Implementation for `Ecto.Repo.get!/3`
  """
  def get!(repo, adapter, queryable, id, opts) do
    one!(repo, adapter, query_for_get(queryable, id), opts)
  end

  def get_by(repo, adapter, queryable, clauses, opts) do
    one(repo, adapter, query_for_get_by(queryable, clauses), opts)
  end

  def get_by!(repo, adapter, queryable, clauses, opts) do
    one!(repo, adapter, query_for_get_by(queryable, clauses), opts)
  end

  @doc """
  Implementation for `Ecto.Repo.one/2`
  """
  def one(repo, adapter, queryable, opts) do
    case all(repo, adapter, queryable, opts) do
      [one] -> one
      []    -> nil
      other -> raise Ecto.MultipleResultsError, queryable: queryable, count: length(other)
    end
  end

  @doc """
  Implementation for `Ecto.Repo.one!/2`
  """
  def one!(repo, adapter, queryable, opts) do
    case all(repo, adapter, queryable, opts) do
      [one] -> one
      []    -> raise Ecto.NoResultsError, queryable: queryable
      other -> raise Ecto.MultipleResultsError, queryable: queryable, count: length(other)
    end
  end

  @doc """
  Runtime callback for `Ecto.Repo.update_all/3`
  """
  def update_all(repo, adapter, queryable, [], opts) when is_list(opts) do
    update_all(repo, adapter, queryable, opts)
  end

  def update_all(repo, adapter, queryable, updates, opts) when is_list(opts) do
    query = Ecto.Query.from q in queryable, update: ^updates
    update_all(repo, adapter, query, opts)
  end

  defp update_all(repo, adapter, queryable, opts) do
    {query, params} =
      Queryable.to_query(queryable)
      |> Planner.query(:update_all, adapter.id_types(repo))
    adapter.update_all(repo, query, params, opts)
  end

  @doc """
  Implementation for `Ecto.Repo.delete_all/2`
  """
  def delete_all(repo, adapter, queryable, opts) when is_list(opts) do
    {query, params} =
      Queryable.to_query(queryable)
      |> Planner.query(:delete_all, adapter.id_types(repo))
    adapter.delete_all(repo, query, params, opts)
  end

  ## Helpers

  defp preprocess(sources, id_types) do
    &preprocess(&1, &2, sources, id_types)
  end

  defp preprocess({:&, _, [ix]}, value, sources, id_types) do
    {source, model} = elem(sources, ix)
    Ecto.Schema.Serializer.load!(model, source, value, id_types)
  end

  defp preprocess({{:., _, [{:&, _, [_]}, _]}, meta, []}, value, _sources, id_types) do
    case Keyword.fetch(meta, :ecto_type) do
      {:ok, type} -> Ecto.Type.load!(type, value, id_types)
      :error      -> value
    end
  end

  defp preprocess(%Ecto.Query.Tagged{tag: tag}, value, _sources, id_types) do
    Ecto.Type.load!(tag, value, id_types)
  end

  defp preprocess(_key, value, _sources, _id_types) do
    value
  end

  defp postprocess(%{expr: expr, fields: fields}) do
    # The planner always put the from as the first
    # entry in the query, avoiding fetching it multiple
    # times even if it appears multiple times in the query.
    # So we always need to handle it specially.
    from? = match?([{:&, _, [0]}|_], fields)
    &postprocess(&1, expr, from?)
  end

  defp postprocess(row, expr, true),
    do: transform_row(expr, hd(row), tl(row)) |> elem(0)
  defp postprocess(row, expr, false),
    do: transform_row(expr, nil, row) |> elem(0)

  defp transform_row({:{}, _, list}, from, values) do
    {result, values} = transform_row(list, from, values)
    {List.to_tuple(result), values}
  end

  defp transform_row({left, right}, from, values) do
    {[left, right], values} = transform_row([left, right], from, values)
    {{left, right}, values}
  end

  defp transform_row({:%{}, _, pairs}, from, values) do
    Enum.reduce pairs, {%{}, values}, fn({key, value}, {map, values_acc}) ->
      {value, new_values} = transform_row(value, from, values_acc)
      {Map.put(map, key, value), new_values}
    end
  end

  defp transform_row(list, from, values) when is_list(list) do
    Enum.map_reduce(list, values, &transform_row(&1, from, &2))
  end

  defp transform_row({:&, _, [0]}, from, values) do
    {from, values}
  end

  defp transform_row(_, _from, values) do
    [value|values] = values
    {value, values}
  end

  defp query_for_get(queryable, id) do
    query = Queryable.to_query(queryable)
    model = assert_model!(query)
    primary_key = primary_key_field!(model)
    Ecto.Query.from(x in query, where: field(x, ^primary_key) == ^id)
  end

  defp query_for_get_by(queryable, clauses) do
    Enum.reduce(clauses, queryable, fn({field, value}, query) ->
      query |> Ecto.Query.where([x], field(x, ^field) == ^value)
    end)
  end

  defp assert_model!(query) do
    case query.from do
      {_source, model} when model != nil ->
        model
      _ ->
        raise Ecto.QueryError,
          query: query,
          message: "expected a from expression with a model"
    end
  end

  defp primary_key_field!(model) when is_atom(model) do
    case model.__schema__(:primary_key) do
      [field] -> field
      _ -> raise Ecto.NoPrimaryKeyError, model: model
    end
  end
end
