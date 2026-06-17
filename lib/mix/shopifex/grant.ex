defmodule Mix.Shopifex.Grant do
  def attrs(),
    do: [
      {:charge_id, :bigint},
      {:grants, {:array, :string}},
      {:remaining_usages, :integer},
      {:total_usages, :integer, default: 0}
    ]

  def assocs(),
    do: [
      {:belongs_to, :shop, :shops}
    ]

  def indexes(),
    do: [
      {:grants, :gin},
      # Postgres does not auto-index foreign-key columns. `grant_for_guard/2`
      # runs on every payment-guarded request and filters by `shop_id`, so a
      # plain btree index here is the difference between an index scan and a
      # sequential scan that grows with the grants table.
      {:shop_id, :index}
    ]
end
