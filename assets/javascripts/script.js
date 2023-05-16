function getUriWithoutDashboard() {
    const reg = new RegExp('(\\/dashboard.*$|\\/$|\\?.*$)');
    let baseUri = location.href;

    if (baseUri.match(reg)!= null) {
        baseUri = baseUri.replace(reg, '');
    }

    return baseUri;
}

function getUriWithDashboard() {
    const baseUri = getUriWithoutDashboard();
    return `${baseUri}/dashboard`;
}

function goToIssue(id) { 
    // const baseUri = getUriWithoutDashboard();
    // location.href = `${baseUri}/issues/${id}`;
    // $('#edit-modal').dialog('open');

    $.ajax({
        url: '/dashboard/issues/' + id,
        method: 'GET',
    });
}

function chooseProject(projectId) {
    if (projectId == "-1") {
        location.search = "";
    } else {
        location.search = `project_id=${projectId}`;   
    }
}

async function setIssueStatus(issueId, newStatus, item, oldContainer, oldIndex) { 
    const response = await fetch(`${getUriWithDashboard()}/set_issue_status/${issueId}/${newStatus.id}`);
    if (!response.ok) {
        oldContainer.insertBefore(item, oldContainer.childNodes[oldIndex + 1]);
        
        $('#drag-result-modal').html(`<p>${await response.json()}</p>`);
        $('#drag-result-modal').dialog('open');
    } else {
        $(item).find('.issue_status_duration > span').css('color', newStatus.color);
        $(item).find('.issue_status_duration > .status').text(newStatus.name);
        $(item).find('.issue_status_duration > .duration').text('less than a minute');
    }
}

function init(useDragAndDrop) {
    document.querySelector('#main-menu').remove();

    document.querySelectorAll('.select_project_item').forEach(item => {
        item.addEventListener('click', function() {
            chooseProject(this.dataset.id);
        })
    });

    const projectsSelector = document.querySelector('#select_project');
    if (projectsSelector != null) {
        projectsSelector.addEventListener('change', function(e) {
            chooseProject(this.value);
        });
    }

    document.querySelector("#content").style.overflow = "hidden"; 

    $('#drag-result-modal').dialog({
      autoOpen: false,
      show: {
        effect: "blind",
        duration: 100
      },
      hide: {
        effect: "explode",
        duration: 100
      }
    });

    $('#edit-modal').dialog({
        autoOpen: false,
        width:'auto',
        modal: true,
    });

    if (useDragAndDrop) {
        document.querySelectorAll('.status_column_closed_issues, .status_column_issues').forEach(item => {
            new Sortable(item, {
                group: 'issues',
                animation: 150,
                draggable: '.issue_card',
                onEnd: async function(evt) {
                    const newStatusEl = evt.to.closest('.status_column');
                    const newStatus = {
                        id: newStatusEl.dataset.id,
                        name: newStatusEl.dataset.name,
                        color:  newStatusEl.dataset.color,
                    };
                    const issueId = evt.item.dataset.id;
    
                    await setIssueStatus(issueId, newStatus,  evt.item, evt.from, evt.oldIndex);
                }
            })
        })
    }
}
