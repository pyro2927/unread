module Unread
  def self.included(base)
    base.extend ActsAsReadable
  end
  
  module ActsAsReadable
    def acts_as_reader
      ReadMark.write_inheritable_attribute :reader_class, self
      
      has_many :read_marks, :dependent => :delete_all
      
      after_create do |user|
        ReadMark.readable_classes.each do |klass|
          klass.mark_as_read! :all, :for => user
        end
      end
    end
    
    def acts_as_readable(options={})
      options.reverse_merge!({ :on => :updated_at })
      class_inheritable_reader :readable_options
      write_inheritable_attribute :readable_options, options
      
      self.has_many :read_marks, :as => :readable, :dependent => :delete_all
      
      classes = ReadMark.readable_classes || []
      classes << self
      ReadMark.write_inheritable_attribute :readable_classes, classes
      
      named_scope :unread_by, lambda { |user| 
        check_reader
        raise ArgumentError unless user.is_a?(ReadMark.reader_class)

        result = { :joins => "LEFT JOIN read_marks ON read_marks.readable_type  = '#{self.base_class.name}'
                                                  AND read_marks.readable_id    = #{self.table_name}.id
                                                  AND read_marks.user_id        = #{user.id}
                                                  AND read_marks.timestamp     >= #{self.table_name}.#{readable_options[:on]}",
                   :conditions => 'read_marks.id IS NULL' }
        if last = timestamp(user)
          result[:conditions] += " AND #{self.table_name}.#{readable_options[:on]} > '#{last.to_s(:db)}'"
        end
        result
      }
      
      extend ClassMethods
      include InstanceMethods
    end
  end
  
  module ClassMethods
    def mark_as_read!(target, options)
      check_reader
      raise ArgumentError unless target == :all || target.is_a?(Array)
      
      user = options[:for]
      raise ArgumentError unless user.is_a?(ReadMark.reader_class)
      
      if target == :all
        reset_read_marks!(user)
      elsif target.is_a?(Array)  
        ReadMark.transaction do
          last = timestamp(user)
      
          target.each do |id|
            raise ArgumentError unless id.is_a?(Integer)
        
            rm = ReadMark.user(user).readable_type(self.base_class.name).find_by_readable_id(id) ||
                 user.read_marks.build(:readable_id => id, :readable_type => self.base_class.name)
            rm.timestamp = Time.now
            rm.save!
          end
        end
      end
    end
    
    def read_mark(user)
      check_reader
      raise ArgumentError unless user.is_a?(ReadMark.reader_class)
      
      user.read_marks.readable_type(self.base_class.name).global.first
    end
    
    def timestamp(user)
      read_mark(user).try(:timestamp)
    end

    def cleanup_read_marks!
      check_reader
      
      ReadMark.reader_class.find_each do |user|
        mark_as_read!(:all, :for => user) unless unread_by(user).exists?
      end
    end
    
    def reset_read_marks!(user = :all)
      check_reader

      ReadMark.transaction do
        if user == :all
          ReadMark.delete_all :readable_type => self.base_class.name
      
          ReadMark.connection.execute("
            INSERT INTO read_marks (user_id, readable_type, timestamp)
            SELECT id, '#{self.base_class.name}', '#{Time.now.to_s(:db)}'
            FROM #{ReadMark.reader_class.table_name}
          ")
        else
          ReadMark.delete_all :readable_type => self.base_class.name, :user_id => user.id
          ReadMark.create!    :readable_type => self.base_class.name, :user_id => user.id, :timestamp => Time.now
        end
      end
      true
    end
    
    def check_reader
      raise RuntimeError, 'Plugin "unread": No reader defined!' unless ReadMark.reader_class
    end
  end
  
  module InstanceMethods 
    def unread?(user)
      self.class.unread_by(user).exists?(self)
    end
    
    def mark_as_read!(options)
      self.class.check_reader
      
      user = options[:for]
      raise ArgumentError unless user.is_a?(ReadMark.reader_class)
      
      ReadMark.transaction do
        if unread?(user)
          rm = read_mark(user) || read_marks.build(:user => user)
          rm.timestamp = Time.now
          rm.save!
        end
      end
    end

    def read_mark(user)
      read_marks.user(user).first
    end
  end
end

ActiveRecord::Base.send :include, Unread