require File.dirname(__FILE__) + '/test_helper.rb'


class TestProfileInfo < Test::Unit::TestCase
  def test_from_s
    name = "[jhpstg] GP[2] +PT -LEX CW[2] +AE NS[4] NT[type] -NB LM[0] FT[:::1] RS[] MM[tao_lmvm] MI[5000] RT[1.0e-8] AT[1.0e-20] VA[1.0e+0] PC[100]"
    p = Delphin::ProfileInfo.from_s(name)
    expected = Delphin::ProfileInfo.new("jhpstg").merge({
     "MM"=>"tao_lmvm", "relative-tolerance"=>1.0e-08, "random-sample-size"=>"",
     "lm-p"=>0, "grandparenting"=>2, "use-preterminal-types-p"=>true,
     "constituent-weight"=>2, "MI"=>5000, "ngram-tag"=>"type",
     "active-edges-p"=>true, "lexicalization-p"=>false,
     "PC"=>100, "AT"=>1.0e-20, "ngram-back-off-p"=>false,
     "ngram-size"=>4, "variance"=>1.0})
    assert_equal(expected, p)
  end
  
  def test_to_s
    p = Delphin::ProfileInfo.new("jhpstg").merge({
     "MM"=>"tao_lmvm", "relative-tolerance"=>1.0e-08, "random-sample-size"=>"",
     "lm-p"=>0, "grandparenting"=>2, "use-preterminal-types-p"=>true,
     "constituent-weight"=>2, "MI"=>5000, "ngram-tag"=>"type",
     "active-edges-p"=>true, "lexicalization-p"=>false,
     "PC"=>100, "AT"=>1.0e-20, "ngram-back-off-p"=>false,
     "ngram-size"=>4, "variance"=>1.0})
     name = "[jhpstg] GP[2] +PT -LEX CW[2] +AE NS[4] NT[type] -NB LM[0] FT[:::1] RS[] MM[tao_lmvm] MI[5000] RT[1.0e-8] AT[1.0e-20] VA[1.0e+0] PC[100]"
     assert_equal(name, p.to_s)
  end

end


class TestParameterRanges < Test::Unit::TestCase

  def test_from_hash
    actual = Delphin::ParameterRanges.from_hash({"a" => [1,2], "b" => [3,4]})
    expected = Delphin::ParameterRanges["a", [1,2], "b", [3,4]]
    assert_equal(expected, actual)
    # One hash value is not an array.
    actual = Delphin::ParameterRanges.from_hash({"a" => [1,2], "b" => [3,4], "c" => 5})
    expected = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5]]
  end

  def test_sum
    r1 = Delphin::ParameterRanges["a", [1], "m", [4]]
    r2 = Delphin::ParameterRanges["z", [3], "m", [5]]
    sum = r1 + r2
    sum.each_key { |parameter| sum[parameter].sort! }
    assert_equal(Delphin::ParameterRanges["a", [1], "m", [4, 5], "z", [3]], sum)
  end

  def test_filtered_ranges
    ranges = Delphin::ParameterRanges["a", [1,2,3], "b", [3,4], "c", [5,6]]
    # Same parameters, different values
    filter = Delphin::ParameterRanges["a", [1,2], "b", [3], "c", [5]]
    assert_equal(Delphin::ParameterRanges["a", [1,2], "b", [3], "c", [5]], ranges.filtered_ranges(filter))
    # Different parameters
    filter = Delphin::ParameterRanges["a", [1,2], "b", [3]]
    assert_equal(Delphin::ParameterRanges["a", [1,2], "b", [3], "c", [5,6]], ranges.filtered_ranges(filter))
    # Same parameters, same values
    filter = Delphin::ParameterRanges["a", [1,2,3], "b", [3,4], "c", [5,6]]
    assert_equal(Delphin::ParameterRanges["a", [1,2,3], "b", [3,4], "c", [5,6]], ranges.filtered_ranges(filter))
  end

  def test_multivalue_ranges
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5]]
    assert_equal(["a", "b"], ranges.multivalue_ranges.sort)
  end
  
  def test_remove_single_value_parameters
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5]]
    assert_equal(Delphin::ParameterRanges["a", [1,2], "b", [3,4]], ranges.remove_single_value_parameters!)
  end
  
  def test_equality
    assert_equal(Delphin::ParameterRanges["a", [1,2], "b", [3,4]],
                 Delphin::ParameterRanges["a", [1,2], "b", [3,4]])
  end
  
  def test_value_combinations
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4]]
    sub_ranges = []
    ranges.each_value_combination {|s| sub_ranges << s}
    expected = [
      Delphin::ParameterRanges["a", [1], "b", [3]],
      Delphin::ParameterRanges["a", [1], "b", [4]],
      Delphin::ParameterRanges["a", [2], "b", [3]],
      Delphin::ParameterRanges["a", [2], "b", [4]],
    ]
    assert_equal(expected, sub_ranges)
  end
  
  def test_value_combinations_with_keep_together
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5,6]]
    sub_ranges = []
    ranges.each_value_combination("c") {|s| sub_ranges << s}
    expected = [
      Delphin::ParameterRanges["a", [1], "b", [3], "c", [5, 6]],
      Delphin::ParameterRanges["a", [1], "b", [4], "c", [5, 6]],
      Delphin::ParameterRanges["a", [2], "b", [3], "c", [5, 6]],
      Delphin::ParameterRanges["a", [2], "b", [4], "c", [5, 6]]
    ]
    assert_equal(expected, sub_ranges)
  end
  
  def test_value_combinations_with_single_parameter
    ranges = Delphin::ParameterRanges["a", [1,2,3]]
    sub_ranges = []
    ranges.each_value_combination {|s| sub_ranges << s}
    expected = [
      Delphin::ParameterRanges["a", [1]],
      Delphin::ParameterRanges["a", [2]],
      Delphin::ParameterRanges["a", [3]]
    ]
    assert_equal(expected, sub_ranges)
  end

  def test_to_s
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5]]
    expected = <<-EOTEXT
a = [1, 2]
b = [3, 4]
c = [5]
EOTEXT
    assert_equal(expected.strip, ranges.to_s)
  end

  def test_to_lisp
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5]]
    expected = <<-EOTEXT
:a '(1 2)
:b '(3 4)
:c 5
EOTEXT
    assert_equal(expected.strip, ranges.to_lisp)
        expected = <<-EOTEXT
:a '(1 2)
:c 5
EOTEXT
    assert_equal(expected.strip, ranges.to_lisp(["a", "c"]))
    ranges = Delphin::ParameterRanges["a", [true, false], "b", [nil], "c", [1e-05], "d", [""]]
    expected = <<-EOTEXT
:a '(t nil)
:b nil
:c 1.0e-5
:d nil
EOTEXT
    assert_equal(expected.strip, ranges.to_lisp)
  end

  def test_exceptions
    ranges = Delphin::ParameterRanges["a", [1,2], "b", [3,4]]
    assert_raise(ArgumentError) { ranges.each_value_combination("c") {|c|} }
  end

end


class TestTSDBSchema < Test::Unit::TestCase

  def setup
    # Actual relations files are longer and have different tables.
    relations = <<-EOTEXT
item:
  i-id :integer :key
  i-origin :string
  i-difficulty :integer
  i-other :string :partial

analysis:
  i-id :integer :key
  a-position :string
  i-foreign :integer :key
EOTEXT
    @relations = Delphin::RelationsFile.new(relations)
  end
  
  def test_relations_file_structure
    assert_equal(["analysis", "item"], @relations.keys.sort)
    assert(@relations.values.all? { |s| s.is_a?(Delphin::ProfileTableSchema) }, "Invalid value types in #{@relations.inspect}")
  end
  
  def test_profile_schema
    # The item table.
    item_table = @relations["item"]
    assert_equal(["i-id", "i-origin", "i-difficulty", "i-other"], item_table.map { |s| s.label })
    assert_equal(["integer", "string", "integer", "string"], item_table.map { |s| s.type })
    assert_equal(Set.new(["i-id"]), item_table.keys)
    assert_equal(Set.new(["i-other"]), item_table.partials)
    # The analysis table.
    analysis_table = @relations["analysis"]
    assert_equal(["i-id", "a-position", "i-foreign"], analysis_table.map { |s| s.label })
    assert_equal(["integer", "string", "integer"], analysis_table.map { |s| s.type })
    assert_equal(Set.new(["i-id", "i-foreign"]), analysis_table.keys)
    assert_equal(Set.new, analysis_table.partials)
  end

  def test_record_creation
    record = @relations["item"].record("52@Muncie@7@else")
    assert_equal({"i-id" => 52, "i-origin" => "Muncie", "i-difficulty" => 7, "i-other" => "else"}, record)
    record = @relations["analysis"].record("17@left@13")
    assert_equal({"i-id" => 17, "a-position" => "left", "i-foreign" => 13}, record)
  end

end
