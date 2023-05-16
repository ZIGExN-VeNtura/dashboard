# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :find_issue, :only => [:find_issue_dashboard, :update_issue_dashboard]

  helper :issues
  helper :projects

  def index
    @use_drop_down_menu = Setting.plugin_dashboard['use_drop_down_menu']
    @selected_project_id = params[:project_id].nil? ? -1 : params[:project_id].to_i
    show_sub_tasks = Setting.plugin_dashboard['display_child_projects_tasks']
    @show_project_badge = @selected_project_id == -1 || @selected_project_id != -1 && show_sub_tasks
    @use_drag_and_drop = Setting.plugin_dashboard['enable_drag_and_drop']
    @display_minimized_closed_issue_cards = Setting.plugin_dashboard['display_closed_statuses'] ? Setting.plugin_dashboard['display_minimized_closed_issue_cards'] : false
    @statuses = get_statuses
    @projects = get_projects
    @issues = get_issues(@selected_project_id, show_sub_tasks)
    @status_journals = get_status_journals_by_issues(@issues)
  end

  def set_issue_status
    issue_id = params[:issue_id].to_i
    status_id = params[:status_id].to_i

    issue = Issue.find(issue_id)
    if issue.new_statuses_allowed_to.select { |item| item.id == status_id }.any?
      issue.init_journal(User.current)
      issue.status_id = status_id
      if issue.save
        head :ok
      else
        # byebug
        # head :forbidden
        messages = Array.wrap(issue).map {|object| object.errors.full_messages}.flatten
        render json: messages, status: :forbidden
        # head :forbidden
      end
    else
      head :forbidden
    end
  end

  def find_issue_dashboard
    @project = @issue.project
    @allowed_statuses = @issue.new_statuses_allowed_to(User.current)
    @priorities = IssuePriority.active

    respond_to do |format|
      format.js { render 'dashboard/edit' }
    end
  end

  def update_issue_dashboard
    original_tracker_id = @issue.tracker_id

    return unless update_issue_from_params
    @issue.save_attachments(params[:attachments] || (params[:issue] && params[:issue][:uploads]))
    saved = false
    begin
      saved = save_issue_with_child_records
    rescue ActiveRecord::StaleObjectError => e
      @conflict = true
      if params[:last_journal_id]
        @conflict_journals = @issue.journals_after(params[:last_journal_id]).to_a
        @conflict_journals.reject!(&:private_notes?) unless User.current.allowed_to?(:view_private_notes, @issue.project)
      end
    end

    if saved
      render_attachment_warning_if_needed(@issue)
      flash[:notice] = l(:notice_successful_update) unless @issue.current_journal.new_record?

      respond_to do |format|
        format.js { render :json => { success: true } }
      end

      if original_tracker_id != 12
        auto_create_subtasks(@issue)
      end
      if original_tracker_id == 12
        auto_delete_subtasks(@issue)
      end

    else
      respond_to do |format|
        format.js { render :json => { success: false, messages: @issue.errors.full_messages }, :status => :unprocessable_entity } 
      end
    end
  end

  # Used by #edit and #update to set some common instance variables
  # from the params
  def update_issue_from_params
    @time_entry = TimeEntry.new(:issue => @issue, :project => @issue.project)
    if params[:time_entry]
      @time_entry.safe_attributes = params[:time_entry]
    end

    @issue.init_journal(User.current)

    issue_attributes = params[:issue]
    if issue_attributes && params[:conflict_resolution]
      case params[:conflict_resolution]
      when 'overwrite'
        issue_attributes = issue_attributes.dup
        issue_attributes.delete(:lock_version)
      when 'add_notes'
        issue_attributes = issue_attributes.slice(:notes, :private_notes)
      when 'cancel'
        redirect_to issue_path(@issue)
        return false
      end
    end
    @issue.safe_attributes = issue_attributes
    @priorities = IssuePriority.active
    @allowed_statuses = @issue.new_statuses_allowed_to(User.current)
    true
  end

  private
  def get_statuses
    data = {}
    items = Setting.plugin_dashboard['display_closed_statuses'] ? IssueStatus.sorted : IssueStatus.sorted.where('is_closed = false')
    items.each do |item|
      data[item.id] = {
        :name => item.name,
        :color => Setting.plugin_dashboard["status_color_" + item.id.to_s],
        :is_closed => item.is_closed
      }
    end
    data
  end

  def get_projects
    data = {-1 => {
      :name => l(:label_all),
      :color => '#4ec7ff'
    }}

    Project.visible.active.each do |item|
      data[item.id] = {
        :name => item.name,
        :color => Setting.plugin_dashboard["project_color_" + item.id.to_s]
      }
    end
    data
  end

  def add_children_ids(id_array, project)
    project.children.each do |child_project|
      id_array.push(child_project.id)
      add_children_ids(id_array, child_project)
    end
  end

  def get_issues(project_id, with_sub_tasks)
    id_array = []

    if project_id != -1
      id_array.push(project_id)
    end

    # fill array of children ids
    if project_id != -1 && with_sub_tasks
      project = Project.find(project_id)
      add_children_ids(id_array, project)
    end
    # byebug
    # @query.issues
    @query = IssueQuery.new(:name => "_")
    # @query.project = @project
    items = id_array.empty? ? @query.issues(limit: 500) : @query.issues(:projects => {:id => id_array}, :limit => 500)

    unless Setting.plugin_dashboard['display_closed_statuses']
      items = items.open
    end

    data = items.map do |item|
      {
        :id => item.id,
        :subject => item.subject,
        :status_id => item.status.id,
        :project_id => item.project.id,
        :created_on => item.created_on,
        :author => item.author.name(User::USER_FORMATS[:firstname_lastname]),
        :executor => item.assigned_to.nil? ? '' : item.assigned_to.name,
        :due_date => item.due_date
      }
    end
    data.sort_by { |item| item[:created_on] }.reverse
  end

  def get_status_journals_by_issues(issues)
    issue_ids = issues.map { |item| item[:id] }
    statusJournals = Journal.includes(:details).where(journal_details: { prop_key: 'status_id' }).
    where(journalized_id: issue_ids).
    where(journalized_type: 'Issue').
    order(created_on: :desc)
  end

  # Auto create 8 subtasks (13/08/2018)
  def auto_create_subtasks(issue)
    return if @issue.tracker_id != 12 #User story
    # only create the subtasks for a user story with a template_id 1
    return if @issue.tracker_id == 12 && params[:issue_template].to_i != 1
    return if Issue.any?{ |i| i.parent_id == @issue.id } #Issue has subtasks

    exclude_project_ids = [106, 107, 108, 109, 110, 111] #2zigexn
    return if exclude_project_ids.include?(issue.project_id)
    subtask_titles = %w(Requirement Design Coding Code\ review Create\ Test\ case Testing Bug\ fixing Release)
    subtask_titles.each do |subtask_title|
      subtask = Issue.new(issue.attributes.except('id', 'created_on', 'updated_on'))
      subtask.subject = subtask_title + ' - ' + subtask.subject
      subtask.tracker_id = 8 #Task
      subtask.parent_issue_id = @issue.id
      subtask.estimated_hours = nil
      subtask.save!
    end
  end
  # Auto delete 8 subtasks (13/08/2018)
  def auto_delete_subtasks(issue)
    exclude_project_ids = [106, 107, 108, 109, 110, 111] #2zigexn
    return if exclude_project_ids.include?(issue.project_id)

    return if @issue.tracker_id != 3 #Support
    #Remove subtasks when change from User Story to Support
    tasks = Issue.where(tracker_id: 8, parent_id: @issue.id)
    tasks.each do |task|
      next if task.description.present?
      next if task.attachments.present?
      next if task.time_entries.present?
      next if task.notes.present?
      next if task.journals.present?
      task.delete
    end
  end

  # Saves @issue and a time_entry from the parameters
  def save_issue_with_child_records
    Issue.transaction do
      if params[:time_entry] && (params[:time_entry][:hours].present? || params[:time_entry][:comments].present?) && User.current.allowed_to?(:log_time, @issue.project)
        time_entry = @time_entry || TimeEntry.new
        time_entry.project = @issue.project
        time_entry.issue = @issue
        time_entry.user = User.current
        time_entry.spent_on = User.current.today
        time_entry.safe_attributes = params[:time_entry]
        @issue.time_entries << time_entry
      end

      call_hook(:controller_issues_edit_before_save, { :params => params, :issue => @issue, :time_entry => time_entry, :journal => @issue.current_journal})
      if @issue.save
        call_hook(:controller_issues_edit_after_save, { :params => params, :issue => @issue, :time_entry => time_entry, :journal => @issue.current_journal})
      else
        raise ActiveRecord::Rollback
      end
    end
  end
end
