class MessagesController < ApplicationController
  def create
    session = current_insurance_session
    raise ProcessingError::NoDocument unless session&.extracted?

    QuestionAnswerer.new(session).call(params[:question])

    redirect_to root_path
  end
end
