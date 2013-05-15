ArJdbc.load_java_part :Derby
require 'arjdbc/jdbc/missing_functionality_helper'

module ArJdbc
  module Derby

    def self.extended(adapter)
      require 'arjdbc/derby/active_record_patch'
      adapter.configure_connection
    end

    def self.included(base)
      require 'arjdbc/derby/active_record_patch'
    end

    def self.column_selector
      [ /derby/i, lambda { |cfg, column| column.extend(::ArJdbc::Derby::Column) } ]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::DerbyJdbcConnection
    end
    
    def configure_connection
      execute("SET ISOLATION = SERIALIZABLE")
      # must be done or SELECT...FOR UPDATE won't work how we expect
    end

    module Column
      
      private

      def extract_limit(sql_type)
        case @sql_type = sql_type.downcase
        when /^smallint/i    then @sql_type = 'smallint'; limit = 2
        when /^bigint/i      then @sql_type = 'bigint'; limit = 8
        when /^double/i      then @sql_type = 'double'; limit = 8 # DOUBLE PRECISION
        when /^real/i        then @sql_type = 'real'; limit = 4
        when /^integer/i     then @sql_type = 'integer'; limit = 4
        when /^datetime/i    then @sql_type = 'datetime'; limit = nil
        when /^timestamp/i   then @sql_type = 'timestamp'; limit = nil
        when /^time/i        then @sql_type = 'time'; limit = nil
        when /^date/i        then @sql_type = 'date'; limit = nil
        when /^xml/i         then @sql_type = 'xml'; limit = nil
        else
          limit = super
          # handle maximum length for a VARCHAR string :
          limit = 32672 if ! limit && @sql_type.index('varchar') == 0
        end
        limit
      end
      
      def simplified_type(field_type)
        case field_type
        when /^smallint/i    then :boolean
        when /^bigint|int/i  then :integer
        when /^real|double/i then :float
        when /^dec/i         then # DEC is a DECIMAL alias
          extract_scale(field_type) == 0 ? :integer : :decimal
        when /^timestamp/i   then :datetime
        when /^xml/i         then :xml
        else
          super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # JDBC returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/
        return nil if value == "GENERATED_BY_DEFAULT"
        value
      end
      
    end

    ADAPTER_NAME = 'Derby'
    
    def adapter_name # :nodoc:
      ADAPTER_NAME
    end

    def self.arel2_visitors(config)
      require 'arel/visitors/derby'
      {
        'derby' => ::Arel::Visitors::Derby,
        'jdbcderby' => ::Arel::Visitors::Derby,
      }
    end

    include ArJdbc::MissingFunctionalityHelper

    def index_name_length
      128
    end

    NATIVE_DATABASE_TYPES = {
      :primary_key => "int GENERATED BY DEFAULT AS identity NOT NULL PRIMARY KEY",
      :string => { :name => "varchar", :limit => 255 },
      :text => { :name => "clob" }, # 2,147,483,647
      :binary => { :name => "blob" }, # 2,147,483,647
      :float => { :name => "float", :limit => 8 }, # DOUBLE PRECISION
      :decimal => { :name => "decimal", :precision => 5, :scale => 0 }, # defaults
      :numeric => { :name => "decimal", :precision => 5, :scale => 0 }, # defaults
      :integer => { :name => "integer", :limit => 4 },
      :smallint => { :name => "smallint", :limit => 2 },
      :bigint => { :name => "bigint", :limit => 8 },
      :real => { :name => "real", :limit => 4 },
      :double => { :name => "double", :limit => 8 },
      :date => { :name => "date" },
      :time => { :name => "time" },
      :datetime => { :name => "timestamp" },
      :timestamp => { :name => "timestamp" },
      :xml => { :name => "xml" },
      :boolean => { :name => "smallint" },
    }
    
    def native_database_types
      super.merge NATIVE_DATABASE_TYPES
    end
    
    def modify_types(types)
      super(types)
      types[:primary_key] = NATIVE_DATABASE_TYPES[:primary_key]
      [ :string, :float, :decimal, :numeric, :integer, 
        :smallint, :bigint, :real, :double, :xml ].each do |type|
        types[type] = NATIVE_DATABASE_TYPES[type].dup
      end
      types[:boolean] = NATIVE_DATABASE_TYPES[:boolean].dup
      types
    end
    
    # in Derby, the following cannot specify a limit :
    NO_LIMIT_TYPES = [ :integer, :boolean, :timestamp, :datetime, :date, :time ] # :nodoc:
    
    # Convert the specified column type to a SQL string.
    def type_to_sql(type, limit = nil, precision = nil, scale = nil) # :nodoc:
      return super unless NO_LIMIT_TYPES.include?(t = type.to_s.downcase.to_sym)

      native_type = NATIVE_DATABASE_TYPES[t]
      native_type.is_a?(Hash) ? native_type[:name] : native_type
    end

    class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition # :nodoc:
      
      def xml(*args)
        options = args.extract_options!
        column(args[0], 'xml', options)
      end
      
    end

    def table_definition(*args)
      new_table_definition(TableDefinition, *args)
    end
    
    # Override default -- fix case where ActiveRecord passes :default => nil, :null => true
    def add_column_options!(sql, options)
      options.delete(:default) if options.has_key?(:default) && options[:default].nil?
      sql << " DEFAULT #{quote(options.delete(:default))}" if options.has_key?(:default)
      super
    end

    # Set the sequence to the max value of the table's column.
    def reset_sequence!(table, column, sequence = nil)
      mpk = select_value("SELECT MAX(#{quote_column_name(column)}) FROM #{quote_table_name(table)}")
      execute("ALTER TABLE #{quote_table_name(table)} ALTER COLUMN #{quote_column_name(column)} RESTART WITH #{mpk.to_i + 1}")
    end

    def reset_pk_sequence!(table, pk = nil, sequence = nil)
      klasses = classes_for_table_name(table)
      klass   = klasses.nil? ? nil : klasses.first
      pk      = klass.primary_key unless klass.nil?
      if pk && klass.columns_hash[pk].type == :integer
        reset_sequence!(klass.table_name, pk)
      end
    end

    def classes_for_table_name(table)
      ActiveRecord::Base.send(:subclasses).select { |klass| klass.table_name == table }
    end
    private :classes_for_table_name
    
    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def rename_table(name, new_name)
      execute "RENAME TABLE #{quote_table_name(name)} TO #{quote_table_name(new_name)}"
    end

    def add_column(table_name, column_name, type, options = {})
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      execute(add_column_sql)
    end

    def execute(sql, name = nil, binds = [])
      sql = to_sql(sql, binds)
      if sql =~ /\A\s*(UPDATE|INSERT)/i
        if ( i = sql =~ /\sWHERE\s/im )
          where_part = sql[i..-1]; sql = sql.dup
          where_part.gsub!(/!=\s*NULL/, 'IS NOT NULL')
          where_part.gsub!(/=\sNULL/i, 'IS NULL')
          sql[i..-1] = where_part
        end
      else
        sql = sql.gsub(/=\sNULL/i, 'IS NULL')
      end
      super(sql, name, binds)
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # Derby requires the ORDER BY columns in the select list for distinct queries, and
    # requires that the ORDER BY include the distinct column.
    #
    #   distinct("posts.id", "posts.created_at desc")
    #
    # Based on distinct method for PostgreSQL Adapter
    def distinct(columns, order_by)
      return "DISTINCT #{columns}" if order_by.blank?

      # construct a clean list of column names from the ORDER BY clause, removing
      # any asc/desc modifiers
      order_columns = [order_by].flatten.map{|o| o.split(',').collect { |s| s.split.first } }.flatten.reject(&:blank?)
      order_columns = order_columns.zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

      # return a DISTINCT clause that's distinct on the columns we want but includes
      # all the required columns for the ORDER BY to work properly
      sql = "DISTINCT #{columns}, #{order_columns * ', '}"
      sql
    end

    SIZEABLE = %w(VARCHAR CLOB BLOB) # :nodoc:

    def structure_dump # :nodoc:
      definition = ""
      meta_data = @connection.connection.meta_data
      tables_rs = meta_data.getTables(nil, nil, nil, ["TABLE"].to_java(:string))
      while tables_rs.next
        table_name = tables_rs.getString(3)
        definition << "CREATE TABLE #{table_name} (\n"
        columns_rs = meta_data.getColumns(nil, nil, table_name, nil)
        first_col = true
        while columns_rs.next
          column_name = add_quotes(columns_rs.getString(4));
          default = ''
          d1 = columns_rs.getString(13)
          if d1 =~ /^GENERATED_/
            default = auto_increment_stmt(table_name, column_name)
          elsif d1
            default = " DEFAULT #{d1}"
          end

          type = columns_rs.getString(6)
          column_size = columns_rs.getString(7)
          nulling = (columns_rs.getString(18) == 'NO' ? " NOT NULL" : "")
          create_column = add_quotes(expand_double_quotes(strip_quotes(column_name)))
          create_column << " #{type}"
          create_column << ( SIZEABLE.include?(type) ? "(#{column_size})" : "" )
          create_column << nulling
          create_column << default
          
          create_column = first_col ? " #{create_column}" : ",\n #{create_column}"
          definition << create_column

          first_col = false
        end
        definition << ");\n\n"
      end
      definition
    end

    AUTO_INC_STMT2 = "" + 
    "SELECT AUTOINCREMENTSTART, AUTOINCREMENTINC, COLUMNNAME, REFERENCEID, COLUMNDEFAULT " + 
    "FROM SYS.SYSCOLUMNS WHERE REFERENCEID = " + 
    "(SELECT T.TABLEID FROM SYS.SYSTABLES T WHERE T.TABLENAME = '%s') AND COLUMNNAME = '%s'"
    
    def auto_increment_stmt(tname, cname)
      stmt = AUTO_INC_STMT2 % [ tname, strip_quotes(cname) ]
      if data = execute(stmt).first
        if start = data['autoincrementstart']
          coldef = ""
          coldef << " GENERATED " << (data['columndefault'].nil? ? "ALWAYS" : "BY DEFAULT ")
          coldef << "AS IDENTITY (START WITH "
          coldef << start
          coldef << ", INCREMENT BY "
          coldef << data['autoincrementinc']
          coldef << ")"
          return coldef
        end
      end
      ""
    end
    private :auto_increment_stmt
    
    def remove_column(table_name, *column_names) # :nodoc:
      for column_name in column_names.flatten
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)} RESTRICT"
      end
    end

    # Notes about changing in Derby:
    #    http://db.apache.org/derby/docs/10.2/ref/rrefsqlj81859.html#rrefsqlj81859__rrefsqlj37860)
    #
    # We support changing columns using the strategy outlined in:
    #    https://issues.apache.org/jira/browse/DERBY-1515
    #
    # This feature has not made it into a formal release and is not in Java 6.
    # We will need to conditionally support this (supposed to arrive for 10.3.0.0).
    def change_column(table_name, column_name, type, options = {})
      # null/not nulling is easy, handle that separately
      if options.include?(:null)
        # This seems to only work with 10.2 of Derby
        if options.delete(:null) == false
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NOT NULL"
        else
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NULL"
        end
      end

      # anything left to do?
      unless options.empty?
        begin
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DATA TYPE #{type_to_sql(type, options[:limit])}"
        rescue
          transaction do
            temp_new_column_name = "#{column_name}_newtype"
            # 1) ALTER TABLE t ADD COLUMN c1_newtype NEWTYPE;
            add_column table_name, temp_new_column_name, type, options
            # 2) UPDATE t SET c1_newtype = c1;
            execute "UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(temp_new_column_name)} = CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit])})"
            # 3) ALTER TABLE t DROP COLUMN c1;
            remove_column table_name, column_name
            # 4) ALTER TABLE t RENAME COLUMN c1_newtype to c1;
            rename_column table_name, temp_new_column_name, column_name
          end
        end
      end
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "RENAME COLUMN #{quote_table_name(table_name)}.#{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
    end

    def primary_keys(table_name)
      @connection.primary_keys table_name.to_s.upcase
    end

    def columns(table_name, name = nil)
      @connection.columns_internal(table_name.to_s, nil, derby_schema)
    end

    def tables
      @connection.tables(nil, derby_schema)
    end

    def recreate_database(db_name, options = {})
      tables.each { |table| drop_table table }
    end

    def quote_column_name(name) # :nodoc:
      %Q{"#{name.to_s.upcase.gsub(/\"/, '""')}"}
    end

    def add_limit_offset!(sql, options) # :nodoc:
      sql << " OFFSET #{options[:offset]} ROWS" if options[:offset]
      # ROWS/ROW and FIRST/NEXT mean the same
      sql << " FETCH FIRST #{options[:limit]} ROWS ONLY" if options[:limit]
    end

    private
    
    def add_quotes(name)
      return name unless name
      %Q{"#{name}"}
    end

    def strip_quotes(str)
      return str unless str
      return str unless /^(["']).*\1$/ =~ str
      str[1..-2]
    end

    def expand_double_quotes(name)
      return name unless name && name['"']
      name.gsub('"', '""')
    end
    
    # Derby appears to define schemas using the username
    def derby_schema
      if @config.has_key?(:schema)
        @config[:schema]
      else
        (@config[:username] && @config[:username].to_s) || ''
      end
    end
    
  end
end
