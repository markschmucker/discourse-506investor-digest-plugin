# frozen_string_literal: true

class AddLastDigestAtToUser < ActiveRecord::Migration[5.2]
  def up
    add_column :users, :last_digest_at, :datetime
  end

  def down
    remove_column :users, :last_digest_at
  end
end
