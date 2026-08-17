# frozen_string_literal: true

class Tag < ActiveRecord::Base
  has_many :post_tags, dependent: :destroy
  has_many :posts, through: :post_tags

  validates :name, presence: true, uniqueness: true
end
