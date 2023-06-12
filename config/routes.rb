get 'dashboard', to: 'dashboard#index'
get 'dashboard/set_issue_status/:issue_id/:status_id', to: 'dashboard#set_issue_status'
get 'dashboard/issues/:id', to: 'dashboard#find_issue_dashboard'
patch 'dashboard/issues/:id', to: 'dashboard#update_issue_dashboard'
