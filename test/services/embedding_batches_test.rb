require "test_helper"

class EmbeddingBatchesTest < ActiveSupport::TestCase
  # The reason this class exists. Measured against the live API: 5 chunks
  # (~3,250 tokens) succeeded and 20 chunks (~13,000 tokens) was rejected, so
  # grouping purely by count builds requests that are refused every time.
  test "keeps every batch inside the token budget" do
    texts = Array.new(40) { "word " * 500 }

    batches = EmbeddingBatches.for(texts)

    assert_operator batches.length, :>, 1
    batches.each do |batch|
      tokens = batch.sum { |t| EmbeddingBatches.estimate(t) }
      assert_operator tokens, :<=, EmbeddingBatches::MAX_TOKENS
    end
  end

  test "respects the API item ceiling even when the texts are tiny" do
    batches = EmbeddingBatches.for(Array.new(250) { "a" })

    assert_equal 3, batches.length
    batches.each { |b| assert_operator b.length, :<=, EmbeddingBatches::MAX_ITEMS }
  end

  test "loses nothing and preserves order" do
    texts = Array.new(120) { |i| "passage number #{i} " * 60 }

    flattened = EmbeddingBatches.for(texts).flatten

    assert_equal texts, flattened
  end

  # A single passage larger than the whole budget still has to go somewhere;
  # dropping it would silently lose part of the document.
  test "an oversized single text gets its own batch rather than being dropped" do
    huge = "word " * 10_000

    batches = EmbeddingBatches.for([ huge, "small" ])

    assert_equal [ [ huge ], [ "small" ] ], batches
  end

  test "no input means no requests" do
    assert_empty EmbeddingBatches.for([])
  end

  test "one small text is one batch" do
    assert_equal [ [ "hello" ] ], EmbeddingBatches.for([ "hello" ])
  end
end
