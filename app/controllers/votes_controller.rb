class VotesController < ApplicationController
  before_filter :find_voteable
  before_filter :check_permissions, :except => [:index]


  def index
    redirect_to(root_path)
  end

  # TODO: refactor
  def create
    vote = Vote.new(:user => current_user)
    vote_type = ""
    if params[:vote_up] || params['vote_up.x'] || params['vote_up.y']
      vote_type = "vote_up"
      vote.value = 1
    elsif params[:vote_down] || params['vote_down.x'] || params['vote_down.y']
      vote_type = "vote_down"
      vote.value = -1
    end

    vote_state = push_vote(vote)

    if vote_state == :created && !vote.new?
      if vote.voteable_type == "Question"
        sweep_question(vote.voteable)

        Magent.push("actors.judge", :on_vote_question, vote.id)
      elsif vote.voteable_type == "Answer"
        Magent.push("actors.judge", :on_vote_answer, vote.id)
      end
    end

    respond_to do |format|
      format.html{redirect_to params[:source]}

      format.js do
        if vote_state != :error
          average = vote.voteable.reload.votes_average
          render(:json => {:success => true,
                           :message => flash[:notice],
                           :vote_type => vote_type,
                           :vote_state => vote_state,
                           :average => average}.to_json)
        else
          render(:json => {:success => false, :message => flash[:error] }.to_json)
        end
      end

      format.json do
        if vote_state != :error
          average = vote.voteable.reload.votes_average
          render(:json => {:success => true,
                           :message => flash[:notice],
                           :vote_type => vote_type,
                           :vote_state => vote_state,
                           :average => average}.to_json)
        else
          render(:json => {:success => false, :message => flash[:error] }.to_json)
        end
      end
    end
  end

  def destroy
    @vote = Vote.find(params[:id])
    voteable = @vote.voteable
    value = @vote.value
    if  @vote && current_user == @vote.user
      @vote.destroy
      if voteable.kind_of?(Question)
        sweep_question(voteable)
      end
      voteable.remove_vote!(value, current_user)
    end
    respond_to do |format|
      format.html { redirect_to params[:source] }
      format.json  { head :ok }
    end
  end

  protected
  def find_voteable
    if params[:answer_id]
      @voteable = current_group.answers.find(params[:answer_id])
    elsif params[:question_id]
      @voteable = current_group.questions.find_by_slug_or_id(params[:question_id])
    end

    if params[:comment_id]
      @voteable = @voteable.comments.find(params[:comment_id])
    end
  end

  def check_permissions
    unless logged_in?
      flash[:error] = t(:unauthenticated, :scope => "votes.create")
      respond_to do |format|
        format.html do
          flash[:error] += ", [#{t("global.please_login")}](#{new_user_session_path})"
          redirect_to params[:source]
        end
        format.json do
          flash[:error] = t("global.please_login")
          render(:json => {:status => :unauthenticate, :success => false, :message => flash[:error] }.to_json)
        end
        format.js do
          flash[:error] = t("global.please_login")
          render(:json => {:status => :unauthenticate, :success => false, :message => flash[:error] }.to_json)
        end
      end
    end
  end

  def push_vote(vote)
    user_vote = current_user.vote_on(@voteable)
    @voteable.votes << vote

    state = :error
    if user_vote.nil?
      @voteable.votes << vote
      if vote.valid?
        @voteable.save # TODO: use modifiers
        @voteable.add_vote!(vote.value, current_user)
        flash[:notice] = t("votes.create.flash_notice")
        state = :created
      else
        flash[:error] = vote.errors.full_messages.join(", ")
      end
    elsif(user_vote.valid?)
      if(user_vote.value != vote.value)
        @voteable.remove_vote!(user_vote.value, current_user)
        @voteable.add_vote!(vote.value, current_user)

        user_vote.value = vote.value
        @voteable.class.collection.update({"votes._id" => user_vote.id},
                                          {"$set" => {:"votes.$.value" => vote.value}})
        flash[:notice] = t("votes.create.flash_notice")
        state = :updated
      else
        value = vote.value
        @voteable.votes.delete_if { |v| v._id ==  vote.id}
        @voteable.save # TODO: use modifiers
        @voteable.remove_vote!(value, current_user)
        flash[:notice] = t("votes.destroy.flash_notice")
        state = :deleted
      end
    else
      flash[:error] = user_vote.errors.full_messages.join(", ")
      state = :error
    end

    if @voteable.is_a?(Answer)
      question = @voteable.question
      sweep_question(question)

      if vote.value == 1
        Question.set(question.id, {:answered_with_id => @voteable.id}) if !question.answered
      elsif question.answered_with_id == @voteable.id && @voteable.votes_average <= 1
        Question.set(question.id, {:answered_with_id => nil})
      end
    end

    state
  end
end
