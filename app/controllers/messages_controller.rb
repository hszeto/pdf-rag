class MessagesController < ApplicationController
  def create
    document = Document.live.find_by(token: params[:document_id])
    raise ProcessingError::NoDocument if document.nil?
    raise ProcessingError::NotReady unless document.ready?

    QuestionAnswerer.new(document).call(params[:question])
    asked, answered = document.messages.ordered.last(2)

    respond_to do |format|
      # Appended rather than navigated to. A redirect re-rendered the whole page,
      # which threw away the reader's position and made a wait of several seconds
      # end in the page jumping to the top.
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove("no-questions"),
          turbo_stream.append("messages", partial: "documents/message", locals: { message: asked }),
          turbo_stream.append("messages", partial: "documents/message",
                                          locals: { message: answered, reveal: true }),
          # Replacing the form is what clears the question that was just asked.
          turbo_stream.replace("ask-form", partial: "documents/ask_form",
                                           locals: { document: document })
        ]
      end

      # Without JavaScript there is no stream to receive, so the page is rebuilt.
      # `asked` rather than a #fragment: Turbo aside, a fragment is never sent to
      # the server, and this path has to work in a browser that has none.
      format.html { redirect_to document_path(document, asked: answered&.id) }
    end
  rescue ProcessingError => e
    # Rendered rather than redirected so the message arrives on the document the
    # reader is already looking at, keeping their place and their history.
    @document = document
    flash.now[:alert] = e.user_message
    return redirect_to(root_path, alert: e.user_message) if @document.nil?

    # Explicitly HTML: the request may have asked for a stream, and Turbo replaces
    # the body of a 422 either way.
    render "documents/show", status: :unprocessable_entity, formats: [ :html ]
  end
end
