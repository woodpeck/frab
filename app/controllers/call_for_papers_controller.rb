class CallForPapersController < ApplicationController

  before_filter :authenticate_user!

  def show
    @call_for_papers = @conference.call_for_papers 
  end

  def new
    @call_for_papers = CallForPapers.new
  end

  def create
    @call_for_papers = CallForPapers.new(params[:call_for_papers])
    @call_for_papers.conference = @conference
    
    if @call_for_papers.save
      redirect_to @call_for_papers, :notice => "Launched Call for Papers."
    else
      render :action => "new"
    end
  end

  def edit
  end

  def update
  end

end