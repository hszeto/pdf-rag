class EnablePgvector < ActiveRecord::Migration[8.1]
  # Vector similarity search over document chunks depends on this. Enabled in a
  # migration rather than by hand so a fresh database — including each test
  # database — gets it without a documented manual step.
  def change
    enable_extension "vector"
  end
end
