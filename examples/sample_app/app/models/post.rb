# frozen_string_literal: true

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments, dependent: :destroy
  has_many :post_tags, dependent: :destroy
  has_many :tags, through: :post_tags

  scope :published, -> { where(published: true) }
end
