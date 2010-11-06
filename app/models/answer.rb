class Answer
  include MongoMapper::Document
  include MongoMapperExt::Filter
  include Support::Versionable
  include Support::Voteable
  include Shapado::Models::GeoCommon
  timestamps!

  key :_id, String

  key :body, String, :required => true
  key :language, String, :default => "en", :index => true
  key :flags_count, Integer, :default => 0
  key :banned, Boolean, :default => false, :index => true
  key :wiki, Boolean, :default => false
  key :anonymous, Boolean, :default => false, :index => true

  key :group_id, String, :index => true
  belongs_to :group

  key :user_id, String, :index => true
  belongs_to :user

  key :updated_by_id, String
  belongs_to :updated_by, :class_name => "User"

  key :question_id, String, :index => true
  belongs_to :question

  has_many :flags

  has_many :comments, :order => "created_at asc"

  validates_presence_of :user_id
  validates_presence_of :question_id

  versionable_keys :body
  filterable_keys :body

  validate :disallow_spam
  validate :check_unique_answer, :if => lambda { |a| (!a.group.forum && !a.disable_limits?) }

  before_destroy :unsolve_question

  def ban
    self.collection.update({:_id => self.id}, {:$set => {:banned => true}})
  end

  def self.ban(ids)
    ids.each do |id|
      self.collection.update({:_id => id}, {:$set => {:banned => true}})
    end
  end

  def can_be_deleted_by?(user)
    ok = (self.user_id == user.id && user.can_delete_own_comments_on?(self.group)) || user.mod_of?(self.group)
    if !ok && user.can_delete_comments_on_own_questions_on?(self.group) && (q = self.question)
      ok = (q.user_id == user.id)
    end

    ok
  end

  def check_unique_answer
    check_answer = Answer.first(:question_id => self.question_id,
                               :user_id => self.user_id)

    if !check_answer.nil? && check_answer.id != self.id
      self.errors.add(:limitation, "Your can only post one answer by question.")
      return false
    end
  end

  def on_add_vote(v, voter)
    if v > 0
      self.user.update_reputation(:answer_receives_up_vote, self.group)
      voter.on_activity(:vote_up_answer, self.group)
    else
      self.user.update_reputation(:answer_receives_down_vote, self.group)
      voter.on_activity(:vote_down_answer, self.group)
    end
  end

  def on_remove_vote(v, voter)
    if v > 0
      self.user.update_reputation(:answer_undo_up_vote, self.group)
      voter.on_activity(:undo_vote_up_answer, self.group)
    else
      self.user.update_reputation(:answer_undo_down_vote, self.group)
      voter.on_activity(:undo_vote_down_answer, self.group)
    end
  end

  def flagged!
    self.increment(:flags_count => 1)
  end


  def ban
    self.question.answer_removed!
    unsolve_question
    self.set({:banned => true})
  end

  def self.ban(ids)
    self.find_each(:_id.in => ids, :select => [:question_id]) do |answer|
      answer.ban
    end
  end

  def to_html
    RDiscount.new(self.body).to_html
  end

  def disable_limits?
    self.user.present? && self.user.can_post_whithout_limits_on?(self.group)
  end

  def disallow_spam
    if new? && !disable_limits?
      eq_answer = Answer.first({:body => self.body,
                                  :question_id => self.question_id,
                                  :group_id => self.group_id
                                })

      last_answer  = Answer.first(:user_id => self.user_id,
                                   :question_id => self.question_id,
                                   :group_id => self.group_id,
                                   :order => "created_at desc")

      valid = (eq_answer.nil? || eq_answer.id == self.id) &&
              ((last_answer.nil?) || (Time.now - last_answer.created_at) > 20)
      if !valid
        self.errors.add(:body, "Your answer is duplicate.")
      end
    end
  end

  protected
  def unsolve_question
    if !self.question.nil? && self.question.answer_id == self.id
      self.question.set({:answer_id => nil, :accepted => false})
    end
  end
end
