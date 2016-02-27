# encoding: utf-8

class Observer::Ticket::Notification::BackgroundJob
  def initialize(params, via_web = false)

=begin
    type: 'update',
    ticket_id: 123,
    changes: {
      'attribute1' => [before,now],
      'attribute2' => [before,now],
    }
=end
    @p = params
    @via_web = via_web
  end

  def perform
    ticket = Ticket.find(@p[:ticket_id])
    if @p[:article_id]
      article = Ticket::Article.find(@p[:article_id])
    end

    # find recipients
    recipients_and_channels = []

=begin
    # group of agents to work on
    if data[:recipient] == 'group'
      recipients = ticket.agent_of_group()

    # owner
    elsif data[:recipient] == 'owner'
      if ticket.owner_id != 1
        recipients.push ticket.owner
      end

    # customer
    elsif data[:recipient] == 'customer'
      if ticket.customer_id != 1
        # temporarily disabled
        #        recipients.push ticket.customer
      end

    # owner or group of agents to work on
    elsif data[:recipient] == 'to_work_on'
      if ticket.owner_id != 1
        recipients.push ticket.owner
      else
        recipients = ticket.agent_of_group()
      end
    end
=end

    # loop through all users
    possible_recipients = ticket.agent_of_group
    if ticket.owner_id == 1
      possible_recipients.push ticket.owner
    end
    already_checked_recipient_ids = {}
    possible_recipients.each {|user|
      result = NotificationFactory.notification_settings(user, ticket, @p[:type])
      next if !result
      next if already_checked_recipient_ids[result[:user].id]
      already_checked_recipient_ids[result[:user].id] = true
      recipients_and_channels.push result
    }

    # send notifications
    recipient_list = ''
    recipients_and_channels.each do |item|
      user = item[:user]
      channels = item[:channels]

      # ignore user who changed it by him self via web
      if @via_web
        next if article && article.updated_by_id == user.id
        next if !article && ticket.updated_by_id == user.id
      end

      # ignore inactive users
      next if !user.active

      # ignore if no changes has been done
      changes = human_changes(user, ticket)
      next if @p[:type] == 'update' && !article && ( !changes || changes.empty? )

      # check if today already notified
      if @p[:type] == 'reminder_reached' || @p[:type] == 'escalation' || @p[:type] == 'escalation_warning'
        identifier = user.email
        if !identifier || identifier == ''
          identifier = user.login
        end
        already_notified = false
        History.list('Ticket', ticket.id).each {|history|
          next if history['type'] != 'notification'
          next if history['value_to'] !~ /\(#{Regexp.escape(@p[:type])}:/
          next if history['value_to'] !~ /#{Regexp.escape(identifier)}\(/
          next if !history['created_at'].today?
          already_notified = true
        }
        next if already_notified
      end

      # create online notification
      used_channels = []
      if channels['online']
        used_channels.push 'online'

        created_by_id = ticket.updated_by_id || 1

        # delete old notifications
        if @p[:type] == 'reminder_reached'
          seen = false
          created_by_id = 1
          OnlineNotification.remove_by_type('Ticket', ticket.id, @p[:type], user)

        elsif @p[:type] == 'escalation' || @p[:type] == 'escalation_warning'
          seen = false
          created_by_id = 1
          OnlineNotification.remove_by_type('Ticket', ticket.id, 'escalation', user)
          OnlineNotification.remove_by_type('Ticket', ticket.id, 'escalation_warning', user)

        # on updates without state changes create unseen messages
        elsif @p[:type] != 'create' && (!@p[:changes] || @p[:changes].empty? || !@p[:changes]['state_id'])
          seen = false
        else
          seen = ticket.online_notification_seen_state(user.id)
        end

        OnlineNotification.add(
          type: @p[:type],
          object: 'Ticket',
          o_id: ticket.id,
          seen: seen,
          created_by_id: created_by_id,
          user_id: user.id,
        )
        Rails.logger.debug "sent ticket online notifiaction to agent (#{@p[:type]}/#{ticket.id}/#{user.email})"
      end

      # ignore email channel notificaiton and empty emails
      if !channels['email'] || !user.email || user.email == ''
        add_recipient_list(ticket, user, used_channels, @p[:type])
        next
      end

      used_channels.push 'email'
      add_recipient_list(ticket, user, used_channels, @p[:type])

      # get user based notification template
      # if create, send create message / block update messages
      template = nil
      if @p[:type] == 'create'
        template = 'ticket_create'
      elsif @p[:type] == 'update'
        template = 'ticket_update'
      elsif @p[:type] == 'reminder_reached'
        template = 'ticket_reminder_reached'
      elsif @p[:type] == 'escalation'
        template = 'ticket_escalation'
      elsif @p[:type] == 'escalation_warning'
        template = 'ticket_escalation_warning'
      else
        fail "unknown type for notification #{@p[:type]}"
      end

      NotificationFactory.notification(
        template: template,
        user: user,
        objects: {
          ticket: ticket,
          article: article,
          recipient: user,
          changes: changes,
        },
        references: ticket.get_references,
        main_object: ticket,
      )
      Rails.logger.debug "sent ticket email notifiaction to agent (#{@p[:type]}/#{ticket.id}/#{user.email})"
    end

  end

  def add_recipient_list(ticket, user, channels, type)
    return if channels.empty?
    identifier = user.email
    if !identifier || identifier == ''
      identifier = user.login
    end
    recipient_list = "#{identifier}(#{type}:#{channels.join(',')})"
    History.add(
      o_id: ticket.id,
      history_type: 'notification',
      history_object: 'Ticket',
      value_to: recipient_list,
      created_by_id: ticket.updated_by_id || 1
    )
  end

  def human_changes(user, record)

    return {} if !@p[:changes]
    locale = user.preferences[:locale] || 'en-us'

    # only show allowed attributes
    attribute_list = ObjectManager::Attribute.by_object_as_hash('Ticket', user)
    #puts "AL #{attribute_list.inspect}"
    user_related_changes = {}
    @p[:changes].each {|key, value|

      # if no config exists, use all attributes
      if !attribute_list || attribute_list.empty?
        user_related_changes[key] = value

      # if config exists, just use existing attributes for user
      elsif attribute_list[key.to_s]
        user_related_changes[key] = value
      end
    }

    changes = {}
    user_related_changes.each {|key, value|

      # get attribute name
      attribute_name           = key.to_s
      object_manager_attribute = attribute_list[attribute_name]
      if attribute_name[-3, 3] == '_id'
        attribute_name = attribute_name[ 0, attribute_name.length - 3 ].to_s
      end

      # add item to changes hash
      if key.to_s == attribute_name
        changes[attribute_name] = value
      end

      # if changed item is an _id field/reference, do an lookup for the realy values
      value_id  = []
      value_str = [ value[0], value[1] ]
      if key.to_s[-3, 3] == '_id'
        value_id[0] = value[0]
        value_id[1] = value[1]

        if record.respond_to?( attribute_name ) && record.send(attribute_name)
          relation_class = record.send(attribute_name).class
          if relation_class && value_id[0]
            relation_model = relation_class.lookup( id: value_id[0] )
            if relation_model
              if relation_model['name']
                value_str[0] = relation_model['name']
              elsif relation_model.respond_to?('fullname')
                value_str[0] = relation_model.send('fullname')
              end
            end
          end
          if relation_class && value_id[1]
            relation_model = relation_class.lookup( id: value_id[1] )
            if relation_model
              if relation_model['name']
                value_str[1] = relation_model['name']
              elsif relation_model.respond_to?('fullname')
                value_str[1] = relation_model.send('fullname')
              end
            end
          end
        end
      end

      # check if we have an dedcated display name for it
      display = attribute_name
      if object_manager_attribute && object_manager_attribute[:display]

        # delete old key
        changes.delete( display )

        # set new key
        display = object_manager_attribute[:display].to_s
      end
      changes[display] = if object_manager_attribute && object_manager_attribute[:translate]
                           from = Translation.translate(locale, value_str[0])
                           to = Translation.translate(locale, value_str[1])
                           [from, to]
                         else
                           [value_str[0].to_s, value_str[1].to_s]
                         end
    }
    changes
  end

end
