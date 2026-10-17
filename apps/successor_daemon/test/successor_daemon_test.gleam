import albedo/harness/extensions
import gleam/list
import gleeunit
import gleeunit/should
import successor_daemon

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn composition_preserves_stock_defaults_and_adds_opt_in_identity_test() {
  let stock = extensions.defaults()
  let product = successor_daemon.composition()
  product.default_enabled |> should.equal(stock.default_enabled)
  product.extensions
  |> list.map(fn(extension) { extension.name })
  |> should.equal(
    list.append(list.map(stock.extensions, fn(extension) { extension.name }), [
      "personality",
    ]),
  )
  product.default_enabled |> list.contains("personality") |> should.be_false
}
