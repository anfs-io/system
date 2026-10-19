# frozen_string_literal: true

RSpec.describe Anfs::Store do
  subject(:store) { described_class.new }

  def result(rows, error: nil) = Anfs::Result.new(rows:, error:, exit_code: error ? 1 : 0)

  it "reports a change only when the result differs" do
    expect(store.put("machines", result([{ "state" => "stopped" }]))).to be(true)
    expect(store.put("machines", result([{ "state" => "stopped" }]))).to be(false)
    expect(store.put("machines", result([{ "state" => "running" }]))).to be(true)
    expect(store.put("machines", result(nil, error: "pmm: boom"))).to be(true)
  end

  it "keeps the time of the last change, not of the last read" do
    store.put("machines", result([]))
    changed_at = store["machines"].changed_at
    store.put("machines", result([]))

    expect(store["machines"].changed_at).to equal(changed_at)
  end

  it "has no rows for a kind that is unread or failing" do
    store.put("machines", result(nil, error: "pmm: boom"))

    expect(store.rows("machines")).to eq([])
    expect(store.rows("containers")).to eq([])
  end
end
